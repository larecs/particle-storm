"""Initial particle population."""

from std.math import floor
from larecs import World
from storm.components import (
    Acceleration,
    Deposit,
    ParticleType,
    Position,
    Velocity,
)
from storm.resources import Bounds


def add_particles(mut world: World[...], count: Int) raises:
    """Adds particles with deterministic positions and alternating types."""
    var bounds = world.resources.read[Bounds]()
    var index = 0
    for particle in world.storage.add_entities(
        Position(0, 0),
        Velocity(0, 0),
        Acceleration(0, 0),
        ParticleType.SNOW,
        Deposit.AIRBORNE,
        count=count,
    ):
        var x = Float32(index) * 0.61803398875
        var y = Float32(index) * 0.75487766625
        particle.get[Position]() = Position(
            (x - floor(x)) * bounds.width, (y - floor(y)) * bounds.height
        )
        particle.get[ParticleType]() = ParticleType(id=index % 2)
        index += 1
