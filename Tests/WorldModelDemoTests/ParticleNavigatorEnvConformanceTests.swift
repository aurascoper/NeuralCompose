import XCTest
@testable import WorldModelDemo

/// `ParticleNavigatorEnv` against the Python original.
///
/// The fixture is generated from `WorldModel/env.py` itself by
/// `tools/worldmodel-fixture/generate.py` in the neuralcompose-client-native
/// repository — not from a reimplementation, which would agree with whatever it
/// was derived from and prove nothing.
///
/// **This is the first thing to pin `step()` against its reference in any
/// language.** The four tests beside this file are hand-computed literals: they
/// check that a bounce reverses and scales, not that a 260-step trajectory
/// matches. A Rust port of the same function reproduced the fixture bit-for-bit
/// on its first run.
///
/// Agreement is asserted **exactly**, not to a tolerance. Both sides are
/// `Float`, the fixture stores each value as a `Float` widened to `Double`
/// (lossless), and a tolerance on a deterministic function could only hide a
/// real divergence. See `docs/acceptance/worldmodel-demo.md` §10 in the client
/// repository for what a failure here means — decided before this ran.
final class ParticleNavigatorEnvConformanceTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Config: Decodable {
            let arenaHalfExtent: Double
            let dt: Double
            let maxAccel: Double
            let maxSpeed: Double
            let restitution: Double
        }
        struct Coverage: Decodable {
            let steps: Int
            let bouncedX: Int
            let bouncedY: Int
            let cornerHits: Int
            let clampedSteps: Int
            let unclampedSteps: Int
        }
        struct Step: Decodable {
            let action: [Double]
            let next: [Double]
            let speedBeforeClamp: Double
            let clamped: Bool
        }
        let schemaId: String
        let config: Config
        let initialState: [Double]
        let coverage: Coverage
        let steps: [Step]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle.module.url(forResource: "env_v1", withExtension: "json") else {
            XCTFail("""
                env_v1.json is not in the test bundle.

                This test does NOT skip when its ground truth is missing: a conformance \
                check that passes when it cannot compare anything reports green for \
                exactly the state it exists to detect.

                Regenerate it in the neuralcompose-client-native checkout with
                  ~/src/NeuralCompose/.venv-muse/bin/python \\
                      tools/worldmodel-fixture/generate.py > env_v1.json
                and copy it to Tests/WorldModelDemoTests/Fixtures/.
                """)
            throw XCTSkip("unreachable — XCTFail above is the real outcome")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func config(_ c: Fixture.Config) -> WorldModelEnvConfig {
        WorldModelEnvConfig(
            arenaHalfExtent: c.arenaHalfExtent,
            dt: c.dt,
            maxAccel: c.maxAccel,
            maxSpeed: c.maxSpeed,
            restitution: c.restitution
        )
    }

    func testEveryStepReproducesThePythonEnvExactly() throws {
        let f = try loadFixture()
        XCTAssertEqual(f.schemaId, "neuralcompose.hypnagogic.env-conformance.v1")

        let cfg = config(f.config)
        var state = f.initialState.map { Float($0) }
        var failures: [String] = []

        for (i, s) in f.steps.enumerated() {
            let action = s.action.map { Float($0) }
            let expected = s.next.map { Float($0) }
            let got = ParticleNavigatorEnv.step(state: state, action: action, config: cfg)

            if got != expected {
                failures.append("""
                    step \(i): action \(action)
                        expected \(expected)
                        got      \(got)
                        python speed before clamp \(s.speedBeforeClamp) (clamped: \(s.clamped))
                    """)
                if failures.count >= 5 {
                    failures.append("… stopping after 5")
                    break
                }
            }
            // Continue from Python's state so one divergence is not reported N times.
            state = expected
        }

        XCTAssertTrue(
            failures.isEmpty,
            """
            ParticleNavigatorEnv.swift diverges from WorldModel/env.py in \
            \(failures.count) place(s):
            \(failures.joined(separator: "\n"))

            Per §10, registered before this test was run: this is a defect in the \
            macOS app's environment, not in the fixture and not a porting artifact. \
            A Rust port of the same function matched this fixture bit-for-bit.
            """
        )
    }

    /// The fixture has to reach the states that discriminate, or a `step` with no
    /// wall handling and no speed limit would pass it.
    func testTheFixtureReachesTheStatesThatDiscriminate() throws {
        let c = try loadFixture().coverage
        XCTAssertGreaterThanOrEqual(c.steps, 200)
        XCTAssertGreaterThan(c.bouncedX, 0, "wall handling is unexercised on x")
        XCTAssertGreaterThan(c.bouncedY, 0, "wall handling is unexercised on y")
        XCTAssertGreaterThan(c.cornerHits, 0, "no step bounces both axes at once")
        XCTAssertGreaterThan(c.clampedSteps, 0, "the speed clamp never fires")
        XCTAssertGreaterThan(
            c.unclampedSteps, 0,
            "the clamp fires on every step — an implementation that always scales would pass"
        )
    }
}
