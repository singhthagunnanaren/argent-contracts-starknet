import { expect } from "chai";
import { ec } from "starknet";
import { declareContract, randomPrivateKey } from "./lib";
import { deployMultisig } from "./lib/multisig";

describe("ArgentMultisig: signer storage", function () {
  let multisigAccountClassHash: string;

  before(async () => {
    multisigAccountClassHash = await declareContract("ArgentMultisigAccount");
  });

  describe("add_signers(new_threshold, signers_to_add)", function () {
    it("Should add one new signer", async function () {
      const threshold = 1;
      const signersLength = 1;

      const new_signer_1 = BigInt(ec.starkCurve.getStarkKey(randomPrivateKey()));
      const new_signer_2 = BigInt(ec.starkCurve.getStarkKey(randomPrivateKey()));

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      const is_signer_0 = await accountContract.is_signer(signers[0]);
      const is_signer_1 = await accountContract.is_signer(new_signer_1);
      expect(is_signer_0).to.be.true;
      expect(is_signer_1).to.be.false;

      await accountContract.add_signers(threshold, [new_signer_1]);

      const is_new_signer_1 = await accountContract.is_signer(new_signer_1);
      expect(is_new_signer_1).to.be.true;

      await accountContract.add_signers(threshold, [new_signer_2]);

      const is_signer_2 = await accountContract.is_signer(new_signer_2);
      expect(is_signer_2).to.be.true;
    });
  });

  describe("remove_signers(new_threshold, signers_to_remove)", function () {
    it("Should remove first signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[0]]);

      const is_signer_0 = await accountContract.is_signer(signers[0]);
      expect(is_signer_0).to.be.false;
    });

    it("Should remove middle signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[1]]);

      const is_signer_1 = await accountContract.is_signer(signers[1]);
      expect(is_signer_1).to.be.false;
    });

    it("Should remove last signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[2]]);

      const is_signer_2 = await accountContract.is_signer(signers[2]);
      expect(is_signer_2).to.be.false;
    });

    it("Should remove first and middle signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[0], signers[1]]);

      const is_signer_0 = await accountContract.is_signer(signers[0]);
      expect(is_signer_0).to.be.false;

      const is_signer_1 = await accountContract.is_signer(signers[1]);
      expect(is_signer_1).to.be.false;
    });

    it("Should remove first and last signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[0], signers[2]]);

      const is_signer_0 = await accountContract.is_signer(signers[0]);
      expect(is_signer_0).to.be.false;

      const is_signer_2 = await accountContract.is_signer(signers[2]);
      expect(is_signer_2).to.be.false;
    });

    it("Should remove middle and last signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[1], signers[2]]);

      const is_signer_1 = await accountContract.is_signer(signers[1]);
      expect(is_signer_1).to.be.false;

      const is_signer_2 = await accountContract.is_signer(signers[2]);
      expect(is_signer_2).to.be.false;
    });

    it("Should remove middle and first signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[1], signers[0]]);

      const is_signer_1 = await accountContract.is_signer(signers[1]);
      expect(is_signer_1).to.be.false;

      const is_signer_0 = await accountContract.is_signer(signers[0]);
      expect(is_signer_0).to.be.false;
    });

    it("Should remove last and first signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[2], signers[0]]);

      const is_signer_2 = await accountContract.is_signer(signers[2]);
      expect(is_signer_2).to.be.false;

      const is_signer_0 = await accountContract.is_signer(signers[0]);
      expect(is_signer_0).to.be.false;
    });

    it("Should remove last and middle signer", async function () {
      const threshold = 1;
      const signersLength = 3;

      const { accountContract, signers } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

      await accountContract.remove_signers(threshold, [signers[2], signers[1]]);

      const is_signer_2 = await accountContract.is_signer(signers[2]);
      expect(is_signer_2).to.be.false;

      const is_signer_1 = await accountContract.is_signer(signers[1]);
      expect(is_signer_1).to.be.false;
    });
  });
});
