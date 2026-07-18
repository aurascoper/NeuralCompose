import Foundation

/// Dependency-free Swift port of `WorldModel/env.py::ParticleNavigatorEnv`.
/// Synthetic-task only — a point mass in a bounded 2D box, actuated by
/// clipped acceleration. Nothing here reads or represents real EEG data.
public enum WorldModelStateDim {
    public static let state = 4  // x, y, vx, vy
    public static let action = 2  // ax, ay
}

public struct WorldModelEnvConfig: Sendable, Equatable {
    public var arenaHalfExtent: Double
    public var dt: Double
    public var maxAccel: Double
    public var maxSpeed: Double
    public var restitution: Double

    public init(
        arenaHalfExtent: Double = 1.0,
        dt: Double = 0.1,
        maxAccel: Double = 1.0,
        maxSpeed: Double = 2.0,
        restitution: Double = 0.6
    ) {
        self.arenaHalfExtent = arenaHalfExtent
        self.dt = dt
        self.maxAccel = maxAccel
        self.maxSpeed = maxSpeed
        self.restitution = restitution
    }
}

/// Stateless, mirroring the Python class exactly — `step`/`reset`/
/// `sampleGoal` all take config/state explicitly rather than mutating any
/// stored instance state.
public enum ParticleNavigatorEnv {
    public static func reset(config: WorldModelEnvConfig, using rng: inout some RandomNumberGenerator) -> [Float] {
        let posX = Double.random(in: -config.arenaHalfExtent...config.arenaHalfExtent, using: &rng)
        let posY = Double.random(in: -config.arenaHalfExtent...config.arenaHalfExtent, using: &rng)
        let velX = Double.random(in: -0.5...0.5, using: &rng) * config.maxSpeed
        let velY = Double.random(in: -0.5...0.5, using: &rng) * config.maxSpeed
        return [Float(posX), Float(posY), Float(velX), Float(velY)]
    }

    /// `state`/return are `[x, y, vx, vy]`, `action` is `[ax, ay]` — matches
    /// `env.py::step` term-for-term (clip acceleration, integrate velocity,
    /// clamp speed, integrate position, wall clamp + restitution bounce).
    public static func step(state: [Float], action: [Float], config: WorldModelEnvConfig) -> [Float] {
        precondition(state.count == WorldModelStateDim.state)
        precondition(action.count == WorldModelStateDim.action)

        let maxAccel = Float(config.maxAccel)
        let dt = Float(config.dt)
        let maxSpeed = Float(config.maxSpeed)
        let restitution = Float(config.restitution)
        let halfExtent = Float(config.arenaHalfExtent)

        var pos = [state[0], state[1]]
        var vel = [state[2], state[3]]

        let accel = action.map { max(-maxAccel, min(maxAccel, $0)) }
        vel = [vel[0] + accel[0] * dt, vel[1] + accel[1] * dt]
        let speed = (vel[0] * vel[0] + vel[1] * vel[1]).squareRoot()
        if speed > maxSpeed {
            let scale = maxSpeed / speed
            vel = [vel[0] * scale, vel[1] * scale]
        }

        var newPos = [pos[0] + vel[0] * dt, pos[1] + vel[1] * dt]
        for dim in 0..<2 {
            if newPos[dim] > halfExtent {
                newPos[dim] = halfExtent
                vel[dim] = -vel[dim] * restitution
            } else if newPos[dim] < -halfExtent {
                newPos[dim] = -halfExtent
                vel[dim] = -vel[dim] * restitution
            }
        }
        pos = newPos

        return [pos[0], pos[1], vel[0], vel[1]]
    }

    public static func sampleGoal(config: WorldModelEnvConfig, using rng: inout some RandomNumberGenerator) -> [Float] {
        let x = Double.random(in: -config.arenaHalfExtent...config.arenaHalfExtent, using: &rng)
        let y = Double.random(in: -config.arenaHalfExtent...config.arenaHalfExtent, using: &rng)
        return [Float(x), Float(y), 0, 0]
    }
}
