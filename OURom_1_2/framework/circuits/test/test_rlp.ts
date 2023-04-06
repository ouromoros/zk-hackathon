// @ts-ignore
import path from "path";

import { expect, assert } from 'chai';
const circom_tester = require('circom_tester');
const wasm_tester = circom_tester.wasm;

import { ethers } from "ethers";
import RLP from 'rlp';
import { get_bsc_message_rlp, headers } from './bsc';


describe("RLP decoding", function () {
    this.timeout(600 * 1000);

    let circuit: any;
    before(async function () {
        console.log("Initialize the circuit test_rlp with wasm tester");
        circuit = await wasm_tester(path.join(__dirname, "circuits", "test_bsc_unoptimized.circom"));
        await circuit.loadConstraints();
        console.log("constraints: " + circuit.constraints.length);
    });

    var test_rlp_decode = function (header: any) {
        console.log("Start test_rlp_decode");
        let chainId = 56;
        let encoded = get_bsc_message_rlp(header, chainId);
        let pubAddress = header.coinbase;

        let RLP_CIRCUIT_MAX_INPUT_LEN = 2150;
        // encoded = smallRLP(header);
        // encoded header -> array of bigint
        let input = new Array(RLP_CIRCUIT_MAX_INPUT_LEN);
        for (let i = 0; i < encoded.length; i++) {
            input[i * 2] = BigInt(encoded[i] >> 4);
            input[i * 2 + 1] = BigInt(encoded[i] & 0xf);
        }
        for (let i = encoded.length * 2; i < RLP_CIRCUIT_MAX_INPUT_LEN; i++) {
            input[i] = BigInt(0);
        }

        it('Testing bsc header, number ' + header.number, async function() {
            let witness = await circuit.calculateWitness(
                {
                    "data": input
                });

            // account address == coinbase
            expect(witness[1]).to.equal(BigInt(header.coinbase));
            // chain ID
            expect(witness[2]).to.equal(BigInt(chainId));
            // block number
            expect(witness[3]).to.equal(BigInt(header.number));
            await circuit.checkConstraints(witness);
        });
    }
    
    headers.forEach(test_rlp_decode);
});