pragma circom 2.0.2;

include "../node_modules/circomlib/circuits/comparators.circom";
include "../node_modules/circomlib/circuits/multiplexer.circom";
include "../node_modules/circomlib/circuits/switcher.circom";

include "bigint.circom";
include "secp256k1.circom";
include "bigint_func.circom";
include "ecdsa_func.circom";
include "secp256k1_func.circom";

// keys are encoded as (x, y) pairs with each coordinate being
// encoded with k registers of n bits each
template ECDSAPrivToPub(n, k) {
    var stride = 8;
    signal input privkey[k];
    signal output pubkey[2][k];

    component n2b[k];
    for (var i = 0; i < k; i++) {
        n2b[i] = Num2Bits(n);
        n2b[i].in <== privkey[i];
    }

    var num_strides = div_ceil(n * k, stride);
    // power[i][j] contains: [j * (1 << stride * i) * G] for 1 <= j < (1 << stride)
    var powers[num_strides][2 ** stride][2][k];
    powers = get_g_pow_stride8_table(n, k);

    // contains a dummy point G * 2 ** 255 to stand in when we are adding 0
    // this point is sometimes an input into AddUnequal, so it must be guaranteed
    // to never equal any possible partial sum that we might get
    var dummyHolder[2][100] = get_dummy_point(n, k);
    var dummy[2][k];
    for (var i = 0; i < k; i++) dummy[0][i] = dummyHolder[0][i];
    for (var i = 0; i < k; i++) dummy[1][i] = dummyHolder[1][i];

    // selector[i] contains a value in [0, ..., 2**i - 1]
    component selectors[num_strides];
    for (var i = 0; i < num_strides; i++) {
        selectors[i] = Bits2Num(stride);
        for (var j = 0; j < stride; j++) {
            var bit_idx1 = (i * stride + j) \ n;
            var bit_idx2 = (i * stride + j) % n;
            if (bit_idx1 < k) {
                selectors[i].in[j] <== n2b[bit_idx1].out[bit_idx2];
            } else {
                selectors[i].in[j] <== 0;
            }
        }
    }

    // multiplexers[i][l].out will be the coordinates of:
    // selectors[i].out * (2 ** (i * stride)) * G    if selectors[i].out is non-zero
    // (2 ** 255) * G                                if selectors[i].out is zero
    component multiplexers[num_strides][2];
    // select from k-register outputs using a 2 ** stride bit selector
    for (var i = 0; i < num_strides; i++) {
        for (var l = 0; l < 2; l++) {
            multiplexers[i][l] = Multiplexer(k, (1 << stride));
            multiplexers[i][l].sel <== selectors[i].out;
            for (var idx = 0; idx < k; idx++) {
                multiplexers[i][l].inp[0][idx] <== dummy[l][idx];
                for (var j = 1; j < (1 << stride); j++) {
                    multiplexers[i][l].inp[j][idx] <== powers[i][j][l][idx];
                }
            }
        }
    }

    component iszero[num_strides];
    for (var i = 0; i < num_strides; i++) {
        iszero[i] = IsZero();
        iszero[i].in <== selectors[i].out;
    }

    // has_prev_nonzero[i] = 1 if at least one of the selections in privkey up to stride i is non-zero
    component has_prev_nonzero[num_strides];
    has_prev_nonzero[0] = OR();
    has_prev_nonzero[0].a <== 0;
    has_prev_nonzero[0].b <== 1 - iszero[0].out;
    for (var i = 1; i < num_strides; i++) {
        has_prev_nonzero[i] = OR();
        has_prev_nonzero[i].a <== has_prev_nonzero[i - 1].out;
        has_prev_nonzero[i].b <== 1 - iszero[i].out;
    }

    signal partial[num_strides][2][k];
    for (var idx = 0; idx < k; idx++) {
        for (var l = 0; l < 2; l++) {
            partial[0][l][idx] <== multiplexers[0][l].out[idx];
        }
    }

    component adders[num_strides - 1];
    signal intermed1[num_strides - 1][2][k];
    signal intermed2[num_strides - 1][2][k];
    for (var i = 1; i < num_strides; i++) {
        adders[i - 1] = Secp256k1AddUnequal(n, k);
        for (var idx = 0; idx < k; idx++) {
            for (var l = 0; l < 2; l++) {
                adders[i - 1].a[l][idx] <== partial[i - 1][l][idx];
                adders[i - 1].b[l][idx] <== multiplexers[i][l].out[idx];
            }
        }

        // partial[i] = has_prev_nonzero[i - 1] * ((1 - iszero[i]) * adders[i - 1].out + iszero[i] * partial[i - 1][0][idx])
        //              + (1 - has_prev_nonzero[i - 1]) * (1 - iszero[i]) * multiplexers[i]
        for (var idx = 0; idx < k; idx++) {
            for (var l = 0; l < 2; l++) {
                intermed1[i - 1][l][idx] <== iszero[i].out * (partial[i - 1][l][idx] - adders[i - 1].out[l][idx]) + adders[i - 1].out[l][idx];
                intermed2[i - 1][l][idx] <== multiplexers[i][l].out[idx] - iszero[i].out * multiplexers[i][l].out[idx];
                partial[i][l][idx] <== has_prev_nonzero[i - 1].out * (intermed1[i - 1][l][idx] - intermed2[i - 1][l][idx]) + intermed2[i - 1][l][idx];
            }
        }
    }

    for (var i = 0; i < k; i++) {
        for (var l = 0; l < 2; l++) {
            pubkey[l][i] <== partial[num_strides - 1][l][i];
        }
    }
}

// r, s, msghash, and pubkey have coordinates
// encoded with k registers of n bits each
// signature is (r, s)
// Does not check that pubkey is valid
template ECDSAVerifyNoPubkeyCheck(n, k) {
    assert(k >= 2);
    assert(k <= 100);

    signal input r[k];
    signal input s[k];
    signal input msghash[k];
    signal input pubkey[2][k];

    signal output result;

    var p[100] = get_secp256k1_prime(n, k);
    var order[100] = get_secp256k1_order(n, k);

    // compute multiplicative inverse of s mod n
    var sinv_comp[100] = mod_inv(n, k, s, order);
    signal sinv[k];
    component sinv_range_checks[k];
    for (var idx = 0; idx < k; idx++) {
        sinv[idx] <-- sinv_comp[idx];
        sinv_range_checks[idx] = Num2Bits(n);
        sinv_range_checks[idx].in <== sinv[idx];
    }
    component sinv_check = BigMultModP(n, k);
    for (var idx = 0; idx < k; idx++) {
        sinv_check.a[idx] <== sinv[idx];
        sinv_check.b[idx] <== s[idx];
        sinv_check.p[idx] <== order[idx];
    }
    for (var idx = 0; idx < k; idx++) {
        if (idx > 0) {
            sinv_check.out[idx] === 0;
        }
        if (idx == 0) {
            sinv_check.out[idx] === 1;
        }
    }

    // compute (h * sinv) mod n
    component g_coeff = BigMultModP(n, k);
    for (var idx = 0; idx < k; idx++) {
        g_coeff.a[idx] <== sinv[idx];
        g_coeff.b[idx] <== msghash[idx];
        g_coeff.p[idx] <== order[idx];
    }

    // compute (h * sinv) * G
    component g_mult = ECDSAPrivToPub(n, k);
    for (var idx = 0; idx < k; idx++) {
        g_mult.privkey[idx] <== g_coeff.out[idx];
    }

    // compute (r * sinv) mod n
    component pubkey_coeff = BigMultModP(n, k);
    for (var idx = 0; idx < k; idx++) {
        pubkey_coeff.a[idx] <== sinv[idx];
        pubkey_coeff.b[idx] <== r[idx];
        pubkey_coeff.p[idx] <== order[idx];
    }

    // compute (r * sinv) * pubkey
    component pubkey_mult = Secp256k1ScalarMult(n, k);
    for (var idx = 0; idx < k; idx++) {
        pubkey_mult.scalar[idx] <== pubkey_coeff.out[idx];
        pubkey_mult.point[0][idx] <== pubkey[0][idx];
        pubkey_mult.point[1][idx] <== pubkey[1][idx];
    }

    // compute (h * sinv) * G + (r * sinv) * pubkey
    component sum_res = Secp256k1AddUnequal(n, k);
    for (var idx = 0; idx < k; idx++) {
        sum_res.a[0][idx] <== g_mult.pubkey[0][idx];
        sum_res.a[1][idx] <== g_mult.pubkey[1][idx];
        sum_res.b[0][idx] <== pubkey_mult.out[0][idx];
        sum_res.b[1][idx] <== pubkey_mult.out[1][idx];
    }

    // compare sum_res.x with r
    component compare[k];
    signal num_equal[k - 1];
    for (var idx = 0; idx < k; idx++) {
        compare[idx] = IsEqual();
        compare[idx].in[0] <== r[idx];
        compare[idx].in[1] <== sum_res.out[0][idx];

        if (idx > 0) {
            if (idx == 1) {
                num_equal[idx - 1] <== compare[0].out + compare[1].out;
            } else {
                num_equal[idx - 1] <== num_equal[idx - 2] + compare[idx].out;
            }
        }
    }
    component res_comp = IsEqual();
    res_comp.in[0] <== k;
    res_comp.in[1] <== num_equal[k - 2];
    result <== res_comp.out;
}

// Included from this PR: https://github.com/0xPARC/circom-ecdsa/pull/18/files
// Checks pubkey is a valid public key by making sure its points are on the curve and that nQ = 0.
// Algorithm from Johnson et al https://doi.org/10.1007/s102070100002 section 6.2
template ECDSACheckPubKey(n, k) {
    assert(n == 64 && k == 4);
    signal input pubkey[2][k];

    // Checks coordinates are in the base field, that Q is on the curve, and that Q != 0
    component point_on_curve = Secp256k1PointOnCurve();
    for (var i = 0; i < 4; i++) {
        point_on_curve.x[i] <== pubkey[0][i];
        point_on_curve.y[i] <== pubkey[1][i];
    }

    // We don't represent 0 as an actual point so we can't directly check that nQ = 0
    // Instead we check that (n - 2)Q = 2(-Q)
    // Note that we can't use (n - 1)Q = -Q since the double and add circuit implicitly tries to calculate nQ and errors
    var order_minus_one[100] = get_secp256k1_order(n, k);
    order_minus_one[0] -= 2;

    component lhs = Secp256k1ScalarMult(n, k);
    for (var i = 0; i < k; i++) {
        lhs.scalar[i] <== order_minus_one[i];
    }
    for (var i = 0; i < k; i++) {
        lhs.point[0][i] <== pubkey[0][i];
        lhs.point[1][i] <== pubkey[1][i];
    }

    // Check each coordinate of our equality independently.
    // Note: Q = (x, y) => -Q = (x, -y)
    // So we can check the x coordinate with [(n-1)*Q].x = Q.x,

    // Because -y === p - y mod p,
    //  we can check the y coordinate with [(n-1)*Q].y = p - Q.y
    var prime[100] = get_secp256k1_prime(n, k);
    component negative_y = BigSub(n, k);
    for (var i = 0; i < k; i++) {
        negative_y.a[i] <== prime[i];
        negative_y.b[i] <== pubkey[1][i];
    }
    negative_y.underflow === 0;

    component rhs = Secp256k1Double(n, k);
    for (var i = 0; i < k; i++) {
        rhs.in[0][i] <== pubkey[0][i];
        rhs.in[1][i] <== negative_y.out[i];
    }

    for (var i = 0; i < k; i++) {
        lhs.out[0][i] === rhs.out[0][i];
        lhs.out[1][i] === rhs.out[1][i];
    }
}

template ECDSARecover(n, k) {
    signal input r[k];
    signal input s[k];
    signal input v;
    signal input msghash[k];

    signal output pubKey[2][k];

    var p[100] = get_secp256k1_prime(n, k);
    var order[100] = get_secp256k1_order(n, k);

    // compute x ** 3
    var square[100] = prod_mod_p(n, k, r, r, p);
    var triple[100] = prod_mod_p(n, k, r, square, p);
    // compute y ** 2 = x ** 3 + 7 (mod p)
    var seven[100];
    for (var i = 0; i < 100; i++) {
        seven[i] = 0;
    }
    seven[0] = 7;
    var minusSeven[100] = long_sub_mod_p(n, k, p, seven, p);
    var ysquare[100] = long_sub_mod_p(n, k, triple, minusSeven, p);
    // compute sqrt(y ** 2)
    var ry[100] = sqrt_mod_p(n, k, ysquare, p);
    // recover y from sqrt(y ** 2) and v
    if (v > 2) {
        ry = long_add(n, k, ry, order);
    }
    if ((v&1)+(ry[0]&1) == 1) {
        ry = long_sub_mod_p(n, k, p, ry, p);
    }
    log("rx", r[0], r[1], r[2], r[3]);
    log("ry", ry[0], ry[1], ry[2], ry[3]);
    // compute multiplicative inverse of r mod order
    var r_inv[100] = mod_inv(n, k, r, order);
    // compute sR
    var r_invs[100] = prod_mod_p(n, k, r_inv, s, order);
    component r_invsr = Secp256k1ScalarMultNoConstraint(n, k);
    for (var i = 0; i < k; i++) {
        r_invsr.scalar[i] <-- r_invs[i];
        r_invsr.point[0][i] <-- r[i];
        r_invsr.point[1][i] <-- ry[i];
    }
    // compute zG
    var r_invz[100] = prod_mod_p(n, k, r_inv, msghash, order);
    component r_invzg = Secp256k1ScalarMultNoConstraint(n, k);
    var gx[100] = get_gx(n, k);
    var gy[100] = get_gy(n, k);
    for (var i = 0; i < k; i++) {
        r_invzg.scalar[i] <-- r_invz[i];
        r_invzg.point[0][i] <-- gx[i];
        r_invzg.point[1][i] <-- gy[i];
    }
    // compute r_invsR - r_invzG
    var neg_r_invzg[2][100];
    neg_r_invzg[0] = r_invzg.out[0];
    neg_r_invzg[1] = long_sub_mod_p(n, k, p, r_invzg.out[1], p);
    var pk[2][100] = secp256k1_addunequal_func(n, k, r_invsr.out[0], r_invsr.out[1], neg_r_invzg[0], neg_r_invzg[1]);

    for (var i = 0; i < k; i++) {
        pubKey[0][i] <-- pk[0][i];
        pubKey[1][i] <-- pk[1][i];
    }

    log("px", pubKey[0][0], pubKey[0][1], pubKey[0][2], pubKey[0][3]);
    log("py", pubKey[1][0], pubKey[1][1], pubKey[1][2], pubKey[1][3]);
    // Ensure pubkey is valid
    component verifyPubKey = ECDSACheckPubKey(n, k);
    for (var i = 0; i < k; i++) {
        verifyPubKey.pubkey[0][i] <== pubKey[0][i];
        verifyPubKey.pubkey[1][i] <== pubKey[1][i];
    }
    // Ensure signature check pass
    component verifyCheck = ECDSAVerifyNoPubkeyCheck(n, k);
    for (var i = 0; i < k; i++) {
        verifyCheck.pubkey[0][i] <== pubKey[0][i];
        verifyCheck.pubkey[1][i] <== pubKey[1][i];
        verifyCheck.r[i] <== r[i];
        verifyCheck.s[i] <== s[i];
        verifyCheck.msghash[i] <== msghash[i];
    }
    verifyCheck.result === 1;
}

// TODO: implement ECDSA extended verify
// r, s, and msghash have coordinates
// encoded with k registers of n bits each
// v is a single bit
// extended signature is (r, s, v)
template ECDSAExtendedVerify(n, k) {
    signal input r[k];
    signal input s[k];
    signal input v;
    signal input msghash[k];

    signal output result;
}
