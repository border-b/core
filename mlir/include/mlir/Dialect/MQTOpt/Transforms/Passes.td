// Copyright (c) 2023 - 2025 Chair for Design Automation, TUM
// Copyright (c) 2025 Munich Quantum Software Company GmbH
// All rights reserved.
//
// SPDX-License-Identifier: MIT
//
// Licensed under the MIT License

#ifndef MQTO_PASSES
#define MQTO_PASSES

include "mlir/Pass/PassBase.td"

def MQTCoreRoundTrip : Pass<"mqt-core-round-trip", "mlir::ModuleOp"> {
  let summary = "This pass performs a round trip to MQT Core's QuantumComputation and back";
  let description = [{
    This pass starts by extracting all quantum-computation-relevant operations and then
    translates them into an MQT Core quantum computation, deleting all quantum operations
    in the process. Then, the quantum computation is read in a second pattern and used
    to generate new MLIR code from it.

    This pass makes the following assumptions:
    - Each module consists of a single function that uses `mqtopt` operations with just a single qubit register.
    - All qubits are measured exactly once and the boolean measurement results are returned from the function in order.
    - The first returned value is the `AllocOp` that constructs a qubit register.
    - Measurements/Operations may only target a single qubit. Unitary operations may also use any number of (positive) controls.
    - Supported operations are `x`, `y`, `z`, `h`, and `measure`.
  }];
}

def CancelConsecutiveInverses : Pass<"cancel-consecutive-inverses", "mlir::ModuleOp"> {
  let summary = "This pass searches for consecutive applications of gates and their inverses and cancels them.";
  let description = [{
    This pass searches for applications of gates that are their own inverses. Walking down their def-use chain,
    it then checks if the same gate is applied once again. In that case, the two gates are cancelled.
  }];
}

def MergeRotationGates : Pass<"merge-rotation-gates", "mlir::ModuleOp"> {
  let summary = "This pass merges consecutive parametrized rotation gates of the same type.";
  let description = [{
    This pass identifies consecutive applications of the same parametrized rotation gate on the same qubits
    and merges them by combining their rotation angles. Supported gates include rx, ry, rz, p, rxx, ryy, rzz,
    rzx, xxminusyy, xxplusyy, u, and u2.

    The pass handles both static and dynamic parameters, and supports an optional tolerance for cancellation
    when the total rotation is close to 0 or 2π.
  }];
  let options = [
    Option<"tolerance", "tolerance", "double", /*default=*/"1e-10",
           "Tolerance for gate cancellation when rotation angle is close to 0 or 2π">,
    Option<"enableCancellation", "enable-cancellation", "bool", /*default=*/"true",
           "Enable rotation gate cancellation when total angle is approximately 0 or 2π">
  ];
}

def QuantumSinkPass : Pass<"quantum-sink", "mlir::ModuleOp"> {
  let summary = "This pass attempts to push down operations into branches for possible optimizations.";
  let description = [{
    This pass searches for branch instructions and attempts to push instructions from previous branches into them.
  }];
}

#endif // MQTO_PASSES
