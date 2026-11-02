#!/usr/bin/env python3
"""run_all_e2e_tests.py - Standalone executable test runner for NeuralCompose E2E test suite.

Executes:
- Tier 1: Feature Coverage (120 tests across 24 features)
- Tier 2: Boundary & Corner Cases (120 tests across 24 features)
- Tier 3: Pairwise Cross-Feature Interactions (29 tests)
- Tier 4: Real-World Application Workloads (6 scenarios)
Total: 275 test cases.

Verifies:
- 100% test pass rate
- Typographic zero-dash hygiene across all test output
- Exit code 0 on complete pass

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time
import unittest

# Ensure REPO_ROOT, REPO_ROOT/tests, and REPO_ROOT/Tests are on sys.path
REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_DIR_LOWER = REPO_ROOT / "tests"
TESTS_DIR_UPPER = REPO_ROOT / "Tests"
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
if str(TESTS_DIR_LOWER) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR_LOWER))
if str(TESTS_DIR_UPPER) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR_UPPER))

from e2e.test_master_event_contract_e2e import (
    TestTier1FeatureCoverage,
    TestTier2BoundaryAndCornerCases,
    TestTier3CrossFeatureInteractions,
    TestTier4RealWorldWorkloads,
)


def run_e2e_test_suite(verbose: bool = True, json_output: bool = False) -> int:
    """Run all 4 tiers of the E2E test suite and print formatted summary."""
    start_time = time.time()
    start_iso = datetime.now(timezone.utc).isoformat()

    suite = unittest.TestSuite()
    loader = unittest.TestLoader()

    tier1_suite = loader.loadTestsFromTestCase(TestTier1FeatureCoverage)
    tier2_suite = loader.loadTestsFromTestCase(TestTier2BoundaryAndCornerCases)
    tier3_suite = loader.loadTestsFromTestCase(TestTier3CrossFeatureInteractions)
    tier4_suite = loader.loadTestsFromTestCase(TestTier4RealWorldWorkloads)

    suite.addTest(tier1_suite)
    suite.addTest(tier2_suite)
    suite.addTest(tier3_suite)
    suite.addTest(tier4_suite)

    total_loaded = suite.countTestCases()
    t1_count = tier1_suite.countTestCases()
    t2_count = tier2_suite.countTestCases()
    t3_count = tier3_suite.countTestCases()
    t4_count = tier4_suite.countTestCases()

    if not json_output:
        print("================================================================================")
        print("NEURALCOMPOSE E2E MASTER EVENT CONTRACT TEST SUITE")
        print(f"Timestamp: {start_iso}")
        print(f"Total Tests Discovered: {total_loaded}")
        print(f"  - Tier 1 (Feature Coverage): {t1_count} tests")
        print(f"  - Tier 2 (Boundary & Corner Cases): {t2_count} tests")
        print(f"  - Tier 3 (Cross-Feature Interactions): {t3_count} tests")
        print(f"  - Tier 4 (Real-World Workloads): {t4_count} scenarios")
        print("================================================================================")

    # Run each tier individually to capture per-tier metrics
    runner = unittest.TextTestRunner(
        stream=open(os.devnull, "w") if json_output else sys.stdout,
        verbosity=2 if verbose and not json_output else 1,
    )

    t1_result = runner.run(tier1_suite)
    t2_result = runner.run(tier2_suite)
    t3_result = runner.run(tier3_suite)
    t4_result = runner.run(tier4_suite)

    elapsed = time.time() - start_time

    total_ran = (
        t1_result.testsRun
        + t2_result.testsRun
        + t3_result.testsRun
        + t4_result.testsRun
    )
    total_failures = (
        len(t1_result.failures)
        + len(t2_result.failures)
        + len(t3_result.failures)
        + len(t4_result.failures)
    )
    total_errors = (
        len(t1_result.errors)
        + len(t2_result.errors)
        + len(t3_result.errors)
        + len(t4_result.errors)
    )
    total_passed = total_ran - total_failures - total_errors
    pass_rate_pct = (total_passed / max(1, total_ran)) * 100.0

    all_passed = (total_failures == 0 and total_errors == 0 and total_ran >= 270)

    summary_data = {
        "timestamp_utc": start_iso,
        "elapsed_seconds": round(elapsed, 4),
        "total_tests": total_ran,
        "passed": total_passed,
        "failures": total_failures,
        "errors": total_errors,
        "pass_rate_pct": round(pass_rate_pct, 2),
        "all_passed": all_passed,
        "tier_breakdown": {
            "tier_1_feature_coverage": {
                "count": t1_result.testsRun,
                "passed": t1_result.testsRun - len(t1_result.failures) - len(t1_result.errors),
                "failures": len(t1_result.failures),
                "errors": len(t1_result.errors),
            },
            "tier_2_boundary_and_corner_cases": {
                "count": t2_result.testsRun,
                "passed": t2_result.testsRun - len(t2_result.failures) - len(t2_result.errors),
                "failures": len(t2_result.failures),
                "errors": len(t2_result.errors),
            },
            "tier_3_cross_feature_interactions": {
                "count": t3_result.testsRun,
                "passed": t3_result.testsRun - len(t3_result.failures) - len(t3_result.errors),
                "failures": len(t3_result.failures),
                "errors": len(t3_result.errors),
            },
            "tier_4_real_world_workloads": {
                "count": t4_result.testsRun,
                "passed": t4_result.testsRun - len(t4_result.failures) - len(t4_result.errors),
                "failures": len(t4_result.failures),
                "errors": len(t4_result.errors),
            },
        },
    }

    # Verify typographic zero-dash hygiene across serialized summary
    summary_json = json.dumps(summary_data, indent=2)
    if "\u2014" in summary_json or "\u2013" in summary_json:
        print("ERROR: Typographic zero-dash hygiene violation in test summary JSON!", file=sys.stderr)
        return 1

    if json_output:
        print(summary_json)
    else:
        print("\n================================================================================")
        print("TEST SUITE EXECUTION SUMMARY")
        print(f"Total Tests Run: {total_ran}")
        print(f"Passed: {total_passed} ({pass_rate_pct:.1f}%)")
        print(f"Failures: {total_failures}")
        print(f"Errors: {total_errors}")
        print(f"Elapsed Time: {elapsed:.3f} s")
        print(f"Overall Result: {'PASSED (100%)' if all_passed else 'FAILED'}")
        print("================================================================================")

    return 0 if all_passed else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Execute full E2E test suite across Tiers 1-4 for NeuralCompose Master Event Contract."
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output test execution report in JSON format.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-test verbosity.",
    )
    args = parser.parse_args(argv)
    return run_e2e_test_suite(verbose=not args.quiet, json_output=args.json)


if __name__ == "__main__":
    sys.exit(main())
