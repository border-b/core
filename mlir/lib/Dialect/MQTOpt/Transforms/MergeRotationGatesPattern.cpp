/*
 * Copyright (c) 2023 - 2025 Chair for Design Automation, TUM
 * Copyright (c) 2025 Munich Quantum Software Company GmbH
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Licensed under the MIT License
 */

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/MQTOpt/IR/MQTOptDialect.h"
#include "mlir/Dialect/MQTOpt/Transforms/Passes.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <iterator>
#include <map>
#include <mlir/IR/Builders.h>
#include <mlir/IR/MLIRContext.h>
#include <mlir/IR/Operation.h>
#include <mlir/IR/PatternMatch.h>
#include <mlir/IR/ValueRange.h>
#include <mlir/Support/LLVM.h>
#include <mlir/Support/LogicalResult.h>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace mqt::ir::opt {

// Utility functions implementation

/**
 * @brief Set of rotation gate names that can be merged.
 */
static const std::set<std::string> ROTATION_GATES = {
    "rx",  "ry",  "rz",        "p",        "rxx", "ryy",
    "rzz", "rzx", "xxminusyy", "xxplusyy", "u",   "u2"};

/**
 * @brief Check if an operation is a rotation gate.
 */
bool isRotationGate(mlir::Operation* op) {
  auto gateName = op->getName().stripDialect().str();
  if (gateName.front() == '.') {
    gateName = gateName.substr(1);
  }
  return ROTATION_GATES.find(gateName) != ROTATION_GATES.end();
}

/**
 * @brief Extract static parameter value if available.
 */
std::optional<double> extractStaticParameter(UnitaryInterface op,
                                             size_t paramIndex) {
  auto staticParamsAttr =
      op->getAttrOfType<mlir::DenseF64ArrayAttr>("static_params");
  if (!staticParamsAttr ||
      static_cast<int64_t>(paramIndex) >= staticParamsAttr.size()) {
    return std::nullopt;
  }

  auto paramsArray = staticParamsAttr.asArrayRef();
  if (paramIndex >= paramsArray.size()) {
    return std::nullopt;
  }

  return paramsArray[paramIndex];
}

/**
 * @brief Extract dynamic parameter value.
 */
mlir::Value extractDynamicParameter(UnitaryInterface op, size_t paramIndex) {
  auto params = op->getOperands().take_front(
      op->getAttrOfType<mlir::DenseI32ArrayAttr>("operand_segment_sizes")
          .asArrayRef()[0]);
  if (paramIndex >= params.size()) {
    return nullptr;
  }
  return params[paramIndex];
}

/**
 * @brief Check if parameter is static.
 */
bool hasStaticParameter(UnitaryInterface op, size_t paramIndex) {
  auto paramsMaskAttr =
      op->getAttrOfType<mlir::DenseBoolArrayAttr>("params_mask");
  if (!paramsMaskAttr ||
      static_cast<int64_t>(paramIndex) >= paramsMaskAttr.size()) {
    // If no mask, assume all parameters are static if static_params exists
    return op->getAttrOfType<mlir::DenseF64ArrayAttr>("static_params") !=
           nullptr;
  }

  auto maskArray = paramsMaskAttr.asArrayRef();
  if (paramIndex >= maskArray.size()) {
    return false;
  }

  return maskArray[paramIndex]; // Mask bit true denotes static, false dynamic
}

/**
 * @brief Normalize angle to [0, 2π) range.
 */
double normalizeAngle(double angle) {
  const double TWO_PI = 2.0 * M_PI;
  return fmod(angle + TWO_PI, TWO_PI);
}

/**
 * @brief Check if angle should be cancelled based on tolerance.
 */
bool shouldCancelAngle(double angle, double tolerance) {
  const double TWO_PI = 2.0 * M_PI;
  double normalized = normalizeAngle(angle);

  // Check if close to 0 or 2π (identity)
  return (normalized < tolerance) || (normalized > TWO_PI - tolerance);
}

/**
 * @brief Get the number of parameters for a gate.
 */
size_t getGateParameterCount(const std::string& gateName) {
  if (gateName == "rx" || gateName == "ry" || gateName == "rz" ||
      gateName == "p" || gateName == "rxx" || gateName == "ryy" ||
      gateName == "rzz" || gateName == "rzx") {
    return 1;
  } else if (gateName == "u2" || gateName == "xxminusyy" ||
             gateName == "xxplusyy") {
    return 2;
  } else if (gateName == "u") {
    return 3;
  }
  return 0;
}

/**
 * @brief Create a new rotation gate with combined parameters.
 */
mlir::Operation* createMergedRotationGate(
    mlir::PatternRewriter& rewriter, UnitaryInterface firstOp,
    UnitaryInterface secondOp, llvm::ArrayRef<mlir::Value> combinedParams,
    llvm::ArrayRef<double> staticParams, llvm::ArrayRef<bool> paramMask) {

  auto* ctx = rewriter.getContext();
  auto loc = firstOp.getLoc();
  auto gateName = firstOp->getName().stripDialect().str();
  if (gateName.front() == '.') {
    gateName = gateName.substr(1);
  }

  // Create attributes
  mlir::DenseF64ArrayAttr staticParamsAttr;
  if (!staticParams.empty()) {
    staticParamsAttr = mlir::DenseF64ArrayAttr::get(ctx, staticParams);
  }

  mlir::DenseBoolArrayAttr paramMaskAttr;
  if (!paramMask.empty() &&
      llvm::any_of(paramMask, [](bool isStatic) { return !isStatic; })) {
    // Only attach the mask attribute if at least one parameter is dynamic.
    paramMaskAttr = mlir::DenseBoolArrayAttr::get(ctx, paramMask);
  }

  // Get input qubits and controls from first operation
  auto inQubits = firstOp.getAllInQubits();
  auto posCtrlInQubits = firstOp.getPosCtrlInQubits();
  auto negCtrlInQubits = firstOp.getNegCtrlInQubits();

  // Get output types from second operation
  auto outQubits = secondOp.getAllOutQubits();
  auto posCtrlOutQubits = secondOp.getPosCtrlOutQubits();
  auto negCtrlOutQubits = secondOp.getNegCtrlOutQubits();

  // Create the new operation
  mlir::OperationState state(loc, "mqtopt." + gateName);

  // Add dynamic parameters (only those marked as dynamic in the mask)
  for (auto param : combinedParams) {
    state.addOperands(param);
  }

  // Add qubits
  state.addOperands(inQubits);
  state.addOperands(posCtrlInQubits);
  state.addOperands(negCtrlInQubits);

  // Add result types
  for (auto qubit : outQubits) {
    state.addTypes(qubit.getType());
  }
  for (auto qubit : posCtrlOutQubits) {
    state.addTypes(qubit.getType());
  }
  for (auto qubit : negCtrlOutQubits) {
    state.addTypes(qubit.getType());
  }

  // Add attributes
  if (staticParamsAttr) {
    state.addAttribute("static_params", staticParamsAttr);
  }
  if (paramMaskAttr) {
    state.addAttribute("params_mask", paramMaskAttr);
  }

  // Add operand segment sizes
  state.addAttribute("operand_segment_sizes",
                     rewriter.getDenseI32ArrayAttr(
                         {static_cast<int32_t>(combinedParams.size()),
                          static_cast<int32_t>(inQubits.size()),
                          static_cast<int32_t>(posCtrlInQubits.size()),
                          static_cast<int32_t>(negCtrlInQubits.size())}));

  // Add result segment sizes
  state.addAttribute("result_segment_sizes",
                     rewriter.getDenseI32ArrayAttr(
                         {static_cast<int32_t>(outQubits.size()),
                          static_cast<int32_t>(posCtrlOutQubits.size()),
                          static_cast<int32_t>(negCtrlOutQubits.size())}));

  return rewriter.create(state);
}

/**
 * @brief This pattern merges consecutive rotation gates of the same type.
 */
struct MergeConsecutiveRotationsPattern final
    : mlir::OpInterfaceRewritePattern<UnitaryInterface> {

  double tolerance;
  bool enableCancellation;

  explicit MergeConsecutiveRotationsPattern(mlir::MLIRContext* context,
                                            double tolerance = 1e-10,
                                            bool enableCancellation = true)
      : OpInterfaceRewritePattern(context), tolerance(tolerance),
        enableCancellation(enableCancellation) {}

  /**
   * @brief Check if two rotation gates can be merged.
   */
  [[nodiscard]] static bool canMergeRotationGates(UnitaryInterface firstOp,
                                                  UnitaryInterface secondOp) {
    // Must be the same gate type
    if (firstOp->getName() != secondOp->getName()) {
      return false;
    }

    // Must be rotation gates
    if (!isRotationGate(firstOp) || !isRotationGate(secondOp)) {
      return false;
    }

    // Must have same target qubits (input of second == output of first)
    auto firstOutQubits = firstOp.getAllOutQubits();
    auto secondInQubits = secondOp.getAllInQubits();

    if (firstOutQubits.size() != secondInQubits.size()) {
      return false;
    }

    for (size_t i = 0; i < firstOutQubits.size(); ++i) {
      if (firstOutQubits[i] != secondInQubits[i]) {
        return false;
      }
    }

    // Must have same control configuration
    if (firstOp.getPosCtrlInQubits().size() !=
            secondOp.getPosCtrlInQubits().size() ||
        firstOp.getNegCtrlInQubits().size() !=
            secondOp.getNegCtrlInQubits().size()) {
      return false;
    }

    // Control qubits must match (input of second == output of first)
    auto firstPosCtrlOut = firstOp.getPosCtrlOutQubits();
    auto secondPosCtrlIn = secondOp.getPosCtrlInQubits();
    if (firstPosCtrlOut.size() != secondPosCtrlIn.size()) {
      return false;
    }
    for (auto [first, second] : llvm::zip(firstPosCtrlOut, secondPosCtrlIn)) {
      if (first != second) {
        return false;
      }
    }

    auto firstNegCtrlOut = firstOp.getNegCtrlOutQubits();
    auto secondNegCtrlIn = secondOp.getNegCtrlInQubits();
    if (firstNegCtrlOut.size() != secondNegCtrlIn.size()) {
      return false;
    }
    for (auto [first, second] : llvm::zip(firstNegCtrlOut, secondNegCtrlIn)) {
      if (first != second) {
        return false;
      }
    }

    return true;
  }

  /**
   * @brief Check if all users of an operation are the same.
   */
  [[nodiscard]] static bool
  areUsersUnique(const mlir::ResultRange::user_range& users) {
    return std::none_of(users.begin(), users.end(),
                        [&](auto* user) { return user != *users.begin(); });
  }

  mlir::LogicalResult match(UnitaryInterface op) const override {
    // Must be a rotation gate
    if (!isRotationGate(op)) {
      return mlir::failure();
    }

    // Collect all unique user operations
    std::set<mlir::Operation*> uniqueUsers;
    for (auto result : op->getResults()) {
      for (auto* user : result.getUsers()) {
        uniqueUsers.insert(user);
      }
    }

    // Must have exactly one unique user operation
    if (uniqueUsers.size() != 1) {
      return mlir::failure();
    }

    auto* user = *uniqueUsers.begin();
    auto secondOp = mlir::dyn_cast<UnitaryInterface>(user);
    if (!secondOp) {
      return mlir::failure();
    }

    // Check if gates can be merged
    if (!canMergeRotationGates(op, secondOp)) {
      return mlir::failure();
    }

    return mlir::success();
  }

  void rewrite(UnitaryInterface firstOp,
               mlir::PatternRewriter& rewriter) const override {
    // Find the unique user operation (same logic as in match)
    std::set<mlir::Operation*> uniqueUsers;
    for (auto result : firstOp->getResults()) {
      for (auto* user : result.getUsers()) {
        uniqueUsers.insert(user);
      }
    }
    auto secondOp = mlir::dyn_cast<UnitaryInterface>(*uniqueUsers.begin());

    auto gateName = firstOp->getName().stripDialect().str();
    if (gateName.front() == '.') {
      gateName = gateName.substr(1);
    }
    size_t paramCount = getGateParameterCount(gateName);

    if (paramCount == 0) {
      return; // Should not happen for rotation gates
    }

    std::vector<mlir::Value> combinedParams;
    // Create full-length vectors to maintain positional indexing
    std::vector<double> staticParams(paramCount, 0.0);
    llvm::SmallVector<bool> paramMask(paramCount, false);

    // Check if all parameters can be cancelled (for early termination)
    bool allCancelled = true;

    // Combine parameters
    for (size_t i = 0; i < paramCount; ++i) {
      bool firstStatic = hasStaticParameter(firstOp, i);
      bool secondStatic = hasStaticParameter(secondOp, i);

      if (firstStatic && secondStatic) {
        // Both static - combine directly
        auto firstVal = extractStaticParameter(firstOp, i);
        auto secondVal = extractStaticParameter(secondOp, i);

        if (!firstVal || !secondVal) {
          return; // Error extracting parameters
        }

        double combinedAngle = *firstVal + *secondVal;

        // Normalize the combined angle
        combinedAngle = normalizeAngle(combinedAngle);

        // Snap to exact common angles to improve textual stability.
        const double PI = M_PI;
        const double HALF_PI = PI / 2.0;
        const double QUARTER_PI = PI / 4.0;
        auto snapIfClose = [&](double target) {
          if (std::abs(combinedAngle - target) < 1e-12) {
            combinedAngle = target;
          }
        };
        snapIfClose(PI);
        snapIfClose(HALF_PI);
        snapIfClose(QUARTER_PI);

        // Check for cancellation of this parameter
        if (enableCancellation && shouldCancelAngle(combinedAngle, tolerance)) {
          // This parameter cancels out, but continue checking others
          staticParams[i] = 0.0;
          paramMask[i] = true; // static (mask bit true marks static)
        } else {
          allCancelled = false;
          staticParams[i] = combinedAngle;
          paramMask[i] = true; // static
        }
      } else {
        allCancelled = false;
        // At least one dynamic - create arith.addf
        mlir::Value firstParam, secondParam;

        if (firstStatic) {
          auto staticVal = extractStaticParameter(firstOp, i);
          if (!staticVal)
            return;
          // Use dynamic parameter type for consistency
          auto existingDynamicParam = extractDynamicParameter(secondOp, i);
          auto paramType = existingDynamicParam ? existingDynamicParam.getType()
                                                : rewriter.getF64Type();
          firstParam = rewriter.create<mlir::arith::ConstantOp>(
              firstOp.getLoc(), paramType,
              rewriter.getF64FloatAttr(*staticVal));
        } else {
          firstParam = extractDynamicParameter(firstOp, i);
        }

        if (secondStatic) {
          auto staticVal = extractStaticParameter(secondOp, i);
          if (!staticVal)
            return;
          // Use dynamic parameter type for consistency
          auto existingDynamicParam = extractDynamicParameter(firstOp, i);
          auto paramType = existingDynamicParam ? existingDynamicParam.getType()
                                                : rewriter.getF64Type();
          secondParam = rewriter.create<mlir::arith::ConstantOp>(
              secondOp.getLoc(), paramType,
              rewriter.getF64FloatAttr(*staticVal));
        } else {
          secondParam = extractDynamicParameter(secondOp, i);
        }

        if (!firstParam || !secondParam) {
          return; // Error extracting parameters
        }

        auto combinedParam = rewriter.create<mlir::arith::AddFOp>(
            firstOp.getLoc(), firstParam, secondParam);

        combinedParams.push_back(combinedParam.getResult());
        paramMask[i] = false; // dynamic (mask bit false marks dynamic)
      }
    }

    // If all parameters cancelled, remove both operations entirely
    if (allCancelled && enableCancellation) {
      // Build explicit SSA value mapping for qubit replacement
      const auto& secondOutQubits = secondOp.getAllOutQubits();
      const auto& firstInQubits = firstOp.getAllInQubits();
      const auto& childUsers = secondOp->getUsers();

      // Build mapping: secondOut -> firstIn
      llvm::DenseMap<mlir::Value, mlir::Value> qubitMapping;
      for (size_t k = 0; k < secondOutQubits.size() && k < firstInQubits.size();
           ++k) {
        qubitMapping[secondOutQubits[k]] = firstInQubits[k];
      }

      for (const auto& childUser : childUsers) {
        for (size_t j = 0; j < childUser->getOperands().size(); j++) {
          const auto& operand = childUser->getOperand(j);
          auto it = qubitMapping.find(operand);
          if (it != qubitMapping.end()) {
            rewriter.modifyOpInPlace(
                childUser, [&] { childUser->setOperand(j, it->second); });
          }
        }
      }

      rewriter.eraseOp(secondOp);
      rewriter.eraseOp(firstOp);
      return;
    }

    // Create the merged gate
    auto* mergedOp = createMergedRotationGate(
        rewriter, firstOp, secondOp, combinedParams, staticParams, paramMask);

    if (!mergedOp) {
      return; // Error creating merged gate
    }

    // Replace uses and erase old operations
    const auto& secondOutQubits = secondOp.getAllOutQubits();
    const auto& mergedResults = mergedOp->getResults();

    for (size_t i = 0; i < secondOutQubits.size(); ++i) {
      mlir::Value outQubit = secondOutQubits[i];
      outQubit.replaceAllUsesWith(mergedResults[i]);
    }

    rewriter.eraseOp(secondOp);
    rewriter.eraseOp(firstOp);
  }
};

/**
 * @brief Populates the given pattern set with rotation merge patterns.
 *
 * @param patterns The pattern set to populate.
 * @param tolerance Tolerance for gate cancellation.
 * @param enableCancellation Whether to enable cancellation.
 */
void populateMergeRotationPatterns(mlir::RewritePatternSet& patterns,
                                   double tolerance, bool enableCancellation) {
  patterns.add<MergeConsecutiveRotationsPattern>(patterns.getContext(),
                                                 tolerance, enableCancellation);
}

} // namespace mqt::ir::opt
