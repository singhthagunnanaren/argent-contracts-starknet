#[account_contract]
mod ArgentAccount {
    use array::ArrayTrait;
    use array::SpanTrait;
    use box::BoxTrait;
    use ecdsa::check_ecdsa_signature;
    use hash::TupleSize4LegacyHash;
    use hash::LegacyHashFelt252;

    use starknet::ClassHash;
    use starknet::class_hash_const;
    use starknet::ContractAddress;
    use starknet::get_block_timestamp;
    use starknet::get_contract_address;
    use starknet::get_tx_info;
    use starknet::VALIDATED;
    use starknet::syscalls::replace_class_syscall;

    use account::Escape;
    use account::EscapeStatus;

    use lib::assert_correct_tx_version;
    use lib::assert_no_self_call;
    use lib::assert_non_reentrant;
    use lib::assert_only_self;
    use lib::execute_multicall;
    use lib::Call;
    use lib::Version;
    use lib::IErc165LibraryDispatcher;
    use lib::IErc165DispatcherTrait;
    use lib::IAccountUpgradeLibraryDispatcher;
    use lib::IAccountUpgradeDispatcherTrait;
    use lib::SpanSerde;

    const NAME: felt252 = 'ArgentAccount';

    const ERC165_IERC165_INTERFACE_ID: felt252 = 0x01ffc9a7;
    // TODO: Update with the latest account interface id for cairo 1. Also deal with the old account version
    const ERC165_ACCOUNT_INTERFACE_ID: felt252 = 0xa66bd575;
    const ERC165_OLD_ACCOUNT_INTERFACE_ID: felt252 = 0x3943f10f;
    const ERC1271_VALIDATED: felt252 = 0x1626ba7e;

    /// Time it takes for the escape to become ready after being triggered
    const ESCAPE_SECURITY_PERIOD: u64 = 604800; // 7 * 24 * 60 * 60;  // 7 days

    ///  The escape will be ready and can be completed for this duration
    const ESCAPE_EXPIRY_PERIOD: u64 = 604800; // 7 * 24 * 60 * 60;  // 7 days

    const ESCAPE_TYPE_GUARDIAN: felt252 = 1;
    const ESCAPE_TYPE_OWNER: felt252 = 2;


    const TRIGGER_ESCAPE_GUARDIAN_SELECTOR: felt252 =
        73865429733192804476769961144708816295126306469589518371407068321865763651; // starknet_keccak('trigger_escape_guardian')
    const TRIGGER_ESCAPE_OWNER_SELECTOR: felt252 =
        1099763735485822105046709698985960101896351570185083824040512300972207240555; // starknet_keccak('trigger_escape_owner')
    const ESCAPE_GUARDIAN_SELECTOR: felt252 =
        1662889347576632967292303062205906116436469425870979472602094601074614456040; // starknet_keccak('escape_guardian')
    const ESCAPE_OWNER_SELECTOR: felt252 =
        1621457541430776841129472853859989177600163870003012244140335395142204209277; // starknet_keccak'(escape_owner')
    const EXECUTE_AFTER_UPGRADE_SELECTOR: felt252 =
        738349667340360233096752603318170676063569407717437256101137432051386874767; // starknet_keccak('execute_after_upgrade')
    const CHANGE_OWNER_SELECTOR: felt252 =
        658036363289841962501247229249022783727527757834043681434485756469236076608; // starknet_keccak('change_owner')

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                           Storage                                          //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    struct Storage {
        _implementation: ClassHash, // This is deprecated and used to migrate cairo 0 accounts only
        _signer: felt252,
        _guardian: felt252,
        _guardian_backup: felt252,
        _escape: Escape,
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                           Events                                           //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[event]
    fn AccountCreated(account: ContractAddress, key: felt252, guardian: felt252) {}

    #[event]
    fn TransactionExecuted(hash: felt252, response: Span<Span<felt252>>) {}

    #[event]
    fn EscapeOwnerTriggered(active_at: u64, new_owner: felt252) {}

    #[event]
    fn EscapeGuardianTriggered(active_at: u64, new_guardian: felt252) {}

    #[event]
    fn OwnerEscaped(new_owner: felt252) {}

    #[event]
    fn GuardianEscaped(new_guardian: felt252) {}

    #[event]
    fn EscapeCanceled() {}

    #[event]
    fn OwnerChanged(new_owner: felt252) {}

    #[event]
    fn GuardianChanged(new_guardian: felt252) {}

    #[event]
    fn GuardianBackupChanged(new_guardian: felt252) {}

    #[event]
    fn AccountUpgraded(new_implementation: ClassHash) {}

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                        Constructor                                         //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[constructor]
    fn constructor(owner: felt252, guardian: felt252) {
        assert(owner != 0, 'argent/null-owner');

        _signer::write(owner);
        _guardian::write(guardian);
        _guardian_backup::write(0);
        AccountCreated(get_contract_address(), owner, guardian);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                     External functions                                     //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[external]
    fn __validate__(calls: Array::<Call>) -> felt252 {
        let account_address = get_contract_address();

        if calls.len() == 1 {
            let call = calls[0];
            if *call.to == account_address {
                let tx_info = get_tx_info().unbox();
                let selector = *call.selector;
                if selector == ESCAPE_GUARDIAN_SELECTOR | selector == TRIGGER_ESCAPE_GUARDIAN_SELECTOR {
                    let is_valid = is_valid_owner_signature(
                        tx_info.transaction_hash, tx_info.signature
                    );
                    assert(is_valid, 'argent/invalid-owner-sig');
                    return VALIDATED;
                }
                if selector == ESCAPE_OWNER_SELECTOR | selector == TRIGGER_ESCAPE_OWNER_SELECTOR {
                    let is_valid = is_valid_guardian_signature(
                        tx_info.transaction_hash, tx_info.signature
                    );
                    assert(is_valid, 'argent/invalid-guardian-sig');
                    return VALIDATED;
                }
                assert(selector != EXECUTE_AFTER_UPGRADE_SELECTOR, 'argent/forbidden-call');
            }
        } else {
            // make sure no call is to the account
            assert_no_self_call(calls.span(), account_address);
        }

        assert_is_valid_signature();

        VALIDATED
    }

    #[external]
    fn __validate_declare__(class_hash: felt252) -> felt252 {
        assert_is_valid_signature();
        VALIDATED
    }

    #[raw_input]
    #[external]
    fn __validate_deploy__(class_hash: felt252, owner: felt252, guardian: felt252) -> felt252 {
        assert_is_valid_signature();
        VALIDATED
    }

    #[external]
    fn __execute__(calls: Array<Call>) -> Span<Span<felt252>> {
        let tx_info = get_tx_info().unbox();
        // assert_correct_tx_version(tx_info.version); // TODO PUT BACK WHEN WE CAN MOCK IT
        assert_non_reentrant();

        let retdata = execute_multicall(calls.span());
        TransactionExecuted(tx_info.transaction_hash, retdata);
        retdata
    }

    /// @notice Changes the owner
    /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
    /// @param new_owner New owner address
    /// @param signature_r Signature R from the new owner 
    /// @param signature_S Signature S from the new owner 
    /// Signature is required to prevent changing to an address which is not in control of the user
    /// Signature is the Signed Message of this hash:
    /// hash = pedersen(0, (change_owner selector, chainid, contract address, old_owner))
    #[external]
    fn change_owner(new_owner: felt252, signature_r: felt252, signature_s: felt252) {
        assert_only_self();
        assert_valid_new_owner(new_owner, signature_r, signature_s);

        _signer::write(new_owner);
        OwnerChanged(new_owner);
    }

    /// @notice Changes the guardian
    /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
    /// @param new_guardian The address of the new guardian, or 0 to disable the guardian
    /// @dev can only be set to 0 if there is no guardian backup set
    #[external]
    fn change_guardian(new_guardian: felt252) {
        assert_only_self();
        // There cannot be a guardian_backup when there is no guardian
        if new_guardian == 0 {
            assert(_guardian_backup::read() == 0, 'argent/backup-should-be-null');
        }

        _guardian::write(new_guardian);
        GuardianChanged(new_guardian);
    }

    /// @notice Changes the backup guardian
    /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
    /// @param new_guardian_backup The address of the new backup guardian, or 0 to disable the backup guardian
    #[external]
    fn change_guardian_backup(new_guardian_backup: felt252) {
        assert_only_self();
        assert_guardian_set();

        _guardian_backup::write(new_guardian_backup);
        GuardianBackupChanged(new_guardian_backup);
    }

    /// @notice Triggers the escape of the owner when it is lost or compromised.
    /// Must be called by the account and authorised by just a guardian.
    /// Cannot override an ongoing escape of the guardian.
    /// @param new_owner The new account owner if the escape completes
    /// @dev
    /// This method checks that there is a guardian, and that `new_owner` is not 0
    #[external]
    fn trigger_escape_owner(new_owner: felt252) {
        assert_only_self();
        assert_guardian_set();
        assert(new_owner != 0, 'argent/null-owner');
        // Can only escape owner by guardian, if there is no escape ongoing other or an escape ongoing but for of the type owner
        let current_escape = _escape::read();
        if (current_escape.escape_type == ESCAPE_TYPE_GUARDIAN) {
            let current_escape_status = get_escape_status(current_escape.active_at);
            assert(
                current_escape_status == EscapeStatus::Expired(()), 'argent/cannot-override-escape'
            );
        }

        reset_escape();
        let active_at = get_block_timestamp() + ESCAPE_SECURITY_PERIOD;
        // TODO Since timestamp is a u64, and escape type 1 small felt252, we can pack those two values and use 1 storage slot
        // TODO We could also inverse the way we store using a map and at ESCAPE_TYPE_OWNER having the escape active_at of the owner and at ESCAPE_TYPE_GUARDIAN escape active_at
        // Since none of these two can be filled at the same time, it'll always use one and only one slot
        // Or we could simplify it by having the struct taking owner_active_at and guardian_active_at and no map
        _escape::write(Escape { active_at, escape_type: ESCAPE_TYPE_OWNER, new_signer: new_owner });
        EscapeOwnerTriggered(active_at, new_owner);
    }

    /// @notice Triggers the escape of the guardian when it is lost or compromised.
    /// Must be called by the account and authorised by the owner alone.
    /// Can override an ongoing escape of the owner.
    /// @param new_guardian The new account guardian if the escape completes
    /// @dev
    /// This method checks that there is a guardian and that `new_guardian` can be 0
    /// if there is no guardian backup (i.e. guardian backup == 0)
    #[external]
    fn trigger_escape_guardian(new_guardian: felt252) {
        assert_only_self();
        assert_guardian_set();

        if new_guardian == 0 {
            assert(_guardian_backup::read() == 0, 'argent/backup-should-be-null');
        }

        reset_escape();

        let active_at = get_block_timestamp() + ESCAPE_SECURITY_PERIOD;
        _escape::write(
            Escape { active_at, escape_type: ESCAPE_TYPE_GUARDIAN, new_signer: new_guardian }
        );
        EscapeGuardianTriggered(active_at, new_guardian);
    }

    /// @notice Completes the escape and changes the owner after the security period
    /// Must be called by the account and authorised by just a guardian
    /// @dev
    /// This method checks that there is a guardian, and that the there is an escape for the owner
    #[external]
    fn escape_owner() {
        assert_only_self();
        assert_guardian_set();

        let current_escape = _escape::read();

        let current_escape_status = get_escape_status(current_escape.active_at);
        assert(current_escape_status == EscapeStatus::Ready(()), 'argent/invalid-escape');
        assert(current_escape.escape_type == ESCAPE_TYPE_OWNER, 'argent/invalid-escape');

        // needed if user started escape in old cairo version and
        // upgraded half way through,  then tries to finish the escape in new version
        assert(current_escape.new_signer != 0, 'argent/null-owner');

        // clear escape
        _escape::write(Escape { active_at: 0, escape_type: 0, new_signer: 0 });
        // update owner
        _signer::write(current_escape.new_signer);
        OwnerEscaped(current_escape.new_signer);
    }

    /// @notice Completes the escape and changes the guardian after the security period
    /// Must be called by the account and authorised by just the owner
    /// @dev
    /// This method assumes that there is a guardian, and that the there is an escape for the guardian
    #[external]
    fn escape_guardian() {
        assert_only_self();
        assert_guardian_set();

        let current_escape = _escape::read();
        let current_escape_status = get_escape_status(current_escape.active_at);
        assert(current_escape_status == EscapeStatus::Ready(()), 'argent/invalid-escape');
        assert(current_escape.escape_type == ESCAPE_TYPE_GUARDIAN, 'argent/invalid-escape');

        // needed if user started escape in old cairo version and
        // upgraded half way through, then tries to finish the escape in new version
        if current_escape.new_signer == 0 {
            assert(_guardian_backup::read() == 0, 'argent/backup-should-be-null');
        }

        // clear escape
        _escape::write(Escape { active_at: 0, escape_type: 0, new_signer: 0 });
        //update guardian
        _guardian::write(current_escape.new_signer);
        GuardianEscaped(current_escape.new_signer);
    }

    /// @notice Cancels an ongoing escape if any.
    /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
    #[external]
    fn cancel_escape() {
        assert_only_self();
        let current_escape = _escape::read();
        let current_escape_status = get_escape_status(current_escape.active_at);
        assert(current_escape_status != EscapeStatus::None(()), 'argent/no-active-escape');
        reset_escape();
    }

    // TODO This could be a trait we impl in another file?
    #[external]
    fn upgrade(implementation: ClassHash, calldata: Array<felt252>) {
        assert_only_self();

        let supports_interface = IErc165LibraryDispatcher {
            class_hash: implementation
        }.supports_interface(ERC165_ACCOUNT_INTERFACE_ID);
        assert(supports_interface, 'argent/invalid-implementation');

        replace_class_syscall(implementation).unwrap_syscall();
        // TODO pass the old version to the callback, careful with backwards compatibility
        IAccountUpgradeLibraryDispatcher {
            class_hash: implementation
        }.execute_after_upgrade(calldata);

        AccountUpgraded(implementation);
    }

    #[external]
    fn execute_after_upgrade(data: Array<felt252>) -> Array::<felt252> {
        assert_only_self();
        let implementation = _implementation::read();
        if implementation != class_hash_const::<0>() {
            replace_class_syscall(implementation).unwrap_syscall();
            _implementation::write(class_hash_const::<0>());
        }
        ArrayTrait::new()
    }
    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                       View functions                                       //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[view]
    fn get_owner() -> felt252 {
        _signer::read()
    }

    #[view]
    fn get_guardian() -> felt252 {
        _guardian::read()
    }

    #[view]
    fn get_guardian_backup() -> felt252 {
        _guardian_backup::read()
    }

    #[view]
    fn get_escape() -> Escape {
        _escape::read()
    }

    #[view]
    fn get_version() -> Version {
        Version { major: 0, minor: 3, patch: 0 }
    }

    #[view]
    fn getVersion() -> felt252 {
        '0.3.0'
    }

    #[view]
    fn get_name() -> felt252 {
        NAME
    }

    #[view]
    fn getName() -> felt252 {
        get_name()
    }

    // add back when updated to latest cairo version
    // currently serde not working for enums
    /// Current escape if any, and its status
    // #[view]
    // fn get_escape_and_status() -> (Escape, EscapeStatus) {
    //     let current_escape = _escape::read();
    //     (current_escape, get_escape_status(current_escape.active_at))
    // }

    // ERC165
    #[view]
    fn supports_interface(interface_id: felt252) -> bool {
        interface_id == ERC165_IERC165_INTERFACE_ID | interface_id == ERC165_ACCOUNT_INTERFACE_ID | interface_id == ERC165_OLD_ACCOUNT_INTERFACE_ID
    }
    #[view]
    fn supportsInterface(interface_id: felt252) -> felt252 {
        if (supports_interface(interface_id)) {
            1
        } else {
            0
        }
    }

    // ERC1271
    #[view]
    fn is_valid_signature(hash: felt252, signatures: Array<felt252>) -> felt252 {
        if is_valid_span_signature(hash, signatures.span()) {
            ERC1271_VALIDATED
        } else {
            0
        }
    }

    #[view]
    fn isValidSignature(hash: felt252, signatures: Array<felt252>) -> felt252 {
        is_valid_signature(hash, signatures)
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                          Internal                                          //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    fn assert_is_valid_signature() {
        let tx_info = get_tx_info().unbox();
        let transaction_hash = tx_info.transaction_hash;
        let full_signature = tx_info.signature;

        let (owner_signature, guardian_signature) = split_signatures(full_signature);
        let is_valid = is_valid_owner_signature(transaction_hash, owner_signature);
        assert(is_valid, 'argent/invalid-owner-sig');
        if _guardian::read() != 0 {
            let is_valid = is_valid_guardian_signature(transaction_hash, guardian_signature);
            assert(is_valid, 'argent/invalid-guardian-sig');
        }
    }

    fn is_valid_span_signature(hash: felt252, signatures: Span<felt252>) -> bool {
        let (owner_signature, guardian_signature) = split_signatures(signatures);
        let is_valid = is_valid_owner_signature(hash, owner_signature);
        if !is_valid {
            return false;
        }
        if _guardian::read() == 0 {
            guardian_signature.is_empty()
        } else {
            is_valid_guardian_signature(hash, guardian_signature)
        }
    }

    fn is_valid_owner_signature(hash: felt252, signature: Span<felt252>) -> bool {
        if signature.len() != 2 {
            return false;
        }
        let signature_r = *signature[0];
        let signature_s = *signature[1];
        check_ecdsa_signature(hash, _signer::read(), signature_r, signature_s)
    }

    fn is_valid_guardian_signature(hash: felt252, signature: Span<felt252>) -> bool {
        if signature.len() != 2 {
            return false;
        }
        let signature_r = *signature[0];
        let signature_s = *signature[1];
        let is_valid = check_ecdsa_signature(hash, _guardian::read(), signature_r, signature_s);
        if is_valid {
            true
        } else {
            check_ecdsa_signature(hash, _guardian_backup::read(), signature_r, signature_s)
        }
    }

    /// The signature is the result of signing the message hash with the new owner private key
    /// The message hash is the result of hashing the array:
    /// [change_owner selector, chainid, contract address, old_owner]
    /// as specified here: https://docs.starknet.io/documentation/architecture_and_concepts/Hashing/hash-functions/#array_hashing

    fn assert_valid_new_owner(new_owner: felt252, signature_r: felt252, signature_s: felt252) {
        assert(new_owner != 0, 'argent/null-owner');
        let chain_id = get_tx_info().unbox().chain_id;
        let mut message_hash = TupleSize4LegacyHash::hash(
            0, (CHANGE_OWNER_SELECTOR, chain_id, get_contract_address(), _signer::read())
        );
        // We now need to hash message_hash with the size of the array: (change_owner selector, chainid, contract address, old_owner)
        // https://github.com/starkware-libs/cairo-lang/blob/b614d1867c64f3fb2cf4a4879348cfcf87c3a5a7/src/starkware/cairo/common/hash_state.py#L6
        message_hash = LegacyHashFelt252::hash(message_hash, 4);
        let is_valid = check_ecdsa_signature(message_hash, new_owner, signature_r, signature_s);
        assert(is_valid, 'argent/invalid-owner-sig');
    }

    fn split_signatures(full_signature: Span<felt252>) -> (Span::<felt252>, Span::<felt252>) {
        if full_signature.len() == 2 {
            return (full_signature, ArrayTrait::new().span());
        }
        assert(full_signature.len() == 4, 'argent/invalid-signature-length');
        (full_signature.slice(0, 2), full_signature.slice(2, 2))
    }

    fn get_escape_status(escape_active_at: u64) -> EscapeStatus {
        if (escape_active_at == 0) {
            return EscapeStatus::None(());
        }

        let block_timestamp = get_block_timestamp();
        if (block_timestamp < escape_active_at) {
            return EscapeStatus::NotReady(());
        }
        if (escape_active_at
            + ESCAPE_EXPIRY_PERIOD <= block_timestamp) {
                return EscapeStatus::Expired(());
            }

        EscapeStatus::Ready(())
    }

    #[inline(always)]
    fn reset_escape() {
        let current_escape = _escape::read();
        let current_escape_status = get_escape_status(current_escape.active_at);
        if current_escape_status == EscapeStatus::None(()) {
            return ();
        }
        _escape::write(Escape { active_at: 0, escape_type: 0, new_signer: 0 });
        if (current_escape_status != EscapeStatus::Expired(())) {
            EscapeCanceled();
        }
    }

    #[inline(always)]
    fn assert_guardian_set() {
        assert(_guardian::read() != 0, 'argent/guardian-required');
    }
}
