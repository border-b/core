// Copyright (c) 2023 - 2025 Chair for Design Automation, TUM
// Copyright (c) 2025 Munich Quantum Software Company GmbH
// All rights reserved.
//
// SPDX-License-Identifier: MIT
//
// Licensed under the MIT License

// RUN: quantum-opt %s -split-input-file --merge-rotation-gates | FileCheck %s

// -----
// This test checks if consecutive rotation gates with static parameters are merged correctly.

module {
  func.func @testMergeStaticRotations() {
    // CHECK: %[[Reg_0:.*]] = "mqtopt.allocQubitRegister"
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 2 : i64}> : () -> !mqtopt.QubitRegister

    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 0 : i64}>
    %reg_1, %q0_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)
    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 1 : i64}>
    %reg_2, %q1_0 = "mqtopt.extractQubit"(%reg_1) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // Test RX merging: π/2 + π/2 = π
    // CHECK: = mqtopt.rx( static [3.141593e+00])
    // CHECK-NOT: mqtopt.rx( static [1.570796e+00])
    %q0_1 = mqtopt.rx(static [1.5707963267948966]) %q0_0 : !mqtopt.Qubit
    %q0_2 = mqtopt.rx(static [1.5707963267948966]) %q0_1 : !mqtopt.Qubit

    // Test RY merging: π/4 + π/4 = π/2
    // CHECK: = mqtopt.ry( static [1.570796e+00])
    // CHECK-NOT: mqtopt.ry( static [7.853982e-01])
    %q1_1 = mqtopt.ry(static [0.7853981633974483]) %q1_0 : !mqtopt.Qubit
    %q1_2 = mqtopt.ry(static [0.7853981633974483]) %q1_1 : !mqtopt.Qubit

    // CHECK: %{{.*}} = "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 0 : i64}>
    %reg_3 = "mqtopt.insertQubit"(%reg_2, %q0_2) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    // CHECK: %{{.*}} = "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 1 : i64}>
    %reg_4 = "mqtopt.insertQubit"(%reg_3, %q1_2) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    // CHECK: "mqtopt.deallocQubitRegister"({{.*}})
    "mqtopt.deallocQubitRegister"(%reg_4) : (!mqtopt.QubitRegister) -> ()
    return
  }
}

// -----
// This test checks if rotation gates that cancel out (total ≈ 2π) are completely removed.

module {
  func.func @testRotationCancellation() {
    // CHECK: %[[Reg_0:.*]] = "mqtopt.allocQubitRegister"
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 1 : i64}> : () -> !mqtopt.QubitRegister

    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 0 : i64}>
    %reg_1, %q_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // Two π rotations should cancel out (2π ≈ 0)
    // CHECK-NOT: mqtopt.rx
    %q_1 = mqtopt.rx(static [3.141592653589793]) %q_0 : !mqtopt.Qubit
    %q_2 = mqtopt.rx(static [3.141592653589793]) %q_1 : !mqtopt.Qubit

    // CHECK: "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 0 : i64}>
    %reg_2 = "mqtopt.insertQubit"(%reg_1, %q_2) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    "mqtopt.deallocQubitRegister"(%reg_2) : (!mqtopt.QubitRegister) -> ()
    return
  }
}

// -----
// This test checks if two-qubit rotation gates are merged correctly.

module {
  func.func @testMergeTwoQubitRotations() {
    // CHECK: %[[Reg_0:.*]] = "mqtopt.allocQubitRegister"
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 2 : i64}> : () -> !mqtopt.QubitRegister

    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 0 : i64}>
    %reg_1, %q0_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)
    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 1 : i64}>
    %reg_2, %q1_0 = "mqtopt.extractQubit"(%reg_1) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // Test RXX merging: π/4 + π/4 = π/2
    // CHECK: = mqtopt.rxx( static [1.570796e+00])
    // CHECK-NOT: mqtopt.rxx( static [7.853982e-01])
    %q01_1:2 = mqtopt.rxx(static [0.7853981633974483]) %q0_0, %q1_0 : !mqtopt.Qubit, !mqtopt.Qubit
    %q01_2:2 = mqtopt.rxx(static [0.7853981633974483]) %q01_1#0, %q01_1#1 : !mqtopt.Qubit, !mqtopt.Qubit

    // CHECK: "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 0 : i64}>
    %reg_3 = "mqtopt.insertQubit"(%reg_2, %q01_2#0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    // CHECK: "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 1 : i64}>
    %reg_4 = "mqtopt.insertQubit"(%reg_3, %q01_2#1) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    "mqtopt.deallocQubitRegister"(%reg_4) : (!mqtopt.QubitRegister) -> ()
    return
  }
}

// -----
// This test checks that non-mergeable rotation gates are not affected.

module {
  func.func @testNonMergeableRotations() {
    // CHECK: %[[Reg_0:.*]] = "mqtopt.allocQubitRegister"
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 2 : i64}> : () -> !mqtopt.QubitRegister

    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 0 : i64}>
    %reg_1, %q0_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)
    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 1 : i64}>
    %reg_2, %q1_0 = "mqtopt.extractQubit"(%reg_1) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // Different gate types - should not merge
    // CHECK: = mqtopt.rx( static [1.570796e+00])
    // CHECK: = mqtopt.ry( static [1.570796e+00])
    %q0_1 = mqtopt.rx(static [1.5707963267948966]) %q0_0 : !mqtopt.Qubit
    %q0_2 = mqtopt.ry(static [1.5707963267948966]) %q0_1 : !mqtopt.Qubit

    // Different target qubits - should not merge
    // CHECK: = mqtopt.rx( static [7.853982e-01])
    %q1_1 = mqtopt.rx(static [0.7853981633974483]) %q1_0 : !mqtopt.Qubit

    %reg_3 = "mqtopt.insertQubit"(%reg_2, %q0_2) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    %reg_4 = "mqtopt.insertQubit"(%reg_3, %q1_1) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    "mqtopt.deallocQubitRegister"(%reg_4) : (!mqtopt.QubitRegister) -> ()
    return
  }
}

// -----
// This test checks tolerance-based cancellation with angles close to 2π.

module {
  func.func @testToleranceBasedCancellation() {
    // CHECK: %[[Reg_0:.*]] = "mqtopt.allocQubitRegister"
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 1 : i64}> : () -> !mqtopt.QubitRegister

    // CHECK: "mqtopt.extractQubit"({{.*}}) <{index_attr = 0 : i64}>
    %reg_1, %q_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // Angles that sum to approximately 2π (within default tolerance 1e-10)
    // π + (π + 1e-12) ≈ 2π + 1e-12, which should cancel with default tolerance
    // CHECK-NOT: mqtopt.ry
    %q_1 = mqtopt.ry(static [3.141592653589793]) %q_0 : !mqtopt.Qubit
    %q_2 = mqtopt.ry(static [3.141592653589794]) %q_1 : !mqtopt.Qubit

    // CHECK: "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 0 : i64}>
    %reg_2 = "mqtopt.insertQubit"(%reg_1, %q_2) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    "mqtopt.deallocQubitRegister"(%reg_2) : (!mqtopt.QubitRegister) -> ()
    return
  }
}

// -----
// This test checks that angles outside tolerance are NOT cancelled.
// RUN: quantum-opt %s -split-input-file --merge-rotation-gates="tolerance=1e-15" | FileCheck %s --check-prefix=STRICT

module {
  func.func @testStrictTolerance() {
    // STRICT: %[[Reg_0:.*]] = "mqtopt.allocQubitRegister"
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 1 : i64}> : () -> !mqtopt.QubitRegister

    // STRICT: "mqtopt.extractQubit"({{.*}}) <{index_attr = 0 : i64}>
    %reg_1, %q_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // With strict tolerance (1e-15), this should NOT cancel but should merge
    // π + (π + 1e-11) = 2π + 1e-11, normalized to ~1e-11 which is outside 1e-15 tolerance
    // STRICT: = mqtopt.rz( static [1.000089e-11])
    %q_1 = mqtopt.rz(static [3.141592653589793]) %q_0 : !mqtopt.Qubit
    %q_2 = mqtopt.rz(static [3.141592653599793]) %q_1 : !mqtopt.Qubit

    // STRICT: "mqtopt.insertQubit"({{.*}}, {{.*}})  <{index_attr = 0 : i64}>
    %reg_2 = "mqtopt.insertQubit"(%reg_1, %q_2) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    "mqtopt.deallocQubitRegister"(%reg_2) : (!mqtopt.QubitRegister) -> ()
    return
  }
}

// -----
// This test verifies coverage for all required gate types for the merge-rotation-gates pass.

module {
  func.func @testAllRequiredGateTypes() {
    %reg_0 = "mqtopt.allocQubitRegister"() <{size_attr = 4 : i64}> : () -> !mqtopt.QubitRegister
    %reg_1, %q0_0 = "mqtopt.extractQubit"(%reg_0) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)
    %reg_2, %q1_0 = "mqtopt.extractQubit"(%reg_1) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)
    %reg_3, %q2_0 = "mqtopt.extractQubit"(%reg_2) <{index_attr = 2 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)
    %reg_4, %q3_0 = "mqtopt.extractQubit"(%reg_3) <{index_attr = 3 : i64}> : (!mqtopt.QubitRegister) -> (!mqtopt.QubitRegister, !mqtopt.Qubit)

    // Test RZ merging (required in issue)
    %q0_1 = mqtopt.rz(static [0.7853981633974483]) %q0_0 : !mqtopt.Qubit
    %q0_2 = mqtopt.rz(static [0.7853981633974483]) %q0_1 : !mqtopt.Qubit

    // Test Phase gate merging (required as "phase" in issue)
    %q1_1 = mqtopt.p(static [0.7853981633974483]) %q1_0 : !mqtopt.Qubit
    %q1_2 = mqtopt.p(static [0.7853981633974483]) %q1_1 : !mqtopt.Qubit

    // Test RZZ merging (required in issue)
    %q23_1:2 = mqtopt.rzz(static [0.7853981633974483]) %q2_0, %q3_0 : !mqtopt.Qubit, !mqtopt.Qubit
    %q23_2:2 = mqtopt.rzz(static [0.7853981633974483]) %q23_1#0, %q23_1#1 : !mqtopt.Qubit, !mqtopt.Qubit

    %reg_5 = "mqtopt.insertQubit"(%reg_4, %q0_2) <{index_attr = 0 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    %reg_6 = "mqtopt.insertQubit"(%reg_5, %q1_2) <{index_attr = 1 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    %reg_7 = "mqtopt.insertQubit"(%reg_6, %q23_2#0) <{index_attr = 2 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    %reg_8 = "mqtopt.insertQubit"(%reg_7, %q23_2#1) <{index_attr = 3 : i64}> : (!mqtopt.QubitRegister, !mqtopt.Qubit) -> !mqtopt.QubitRegister
    "mqtopt.deallocQubitRegister"(%reg_8) : (!mqtopt.QubitRegister) -> ()
    return
  }
}
