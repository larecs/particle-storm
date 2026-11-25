"""CreationSystem: creates the initial particles."""

from std.math import floor
from larecs import Filter, KernelContext, Resources, System, SystemContext
from storm.components import (
    Acceleration,
    Deposit,
    ParticleType,
    Position,
    Velocity,
)
from storm.resources import Bounds


def creation_kernel(
    context: KernelContext[
        Filter().write[Position, ParticleType](), Resources[]().read[Bounds]()
    ]
):
    ref bounds = context.resources.get[Bounds]()
    for particle in context:
        var pos = Position(
            x=Float32(particle.idx) * 0.61803398875,
            y=Float32(particle.idx) * 0.75487766625,
        )
        pos.x = (pos.x - floor(pos.x)) * bounds.width
        pos.y = (pos.y - floor(pos.y)) * bounds.height

        particle.set[Position](pos)
        particle.set[ParticleType](ParticleType(id=particle.idx % 2))


@fieldwise_init
struct CreationSystem(System):
    var entity_count: Int

    def initialize(mut self, mut system: SystemContext[...]) raises:
        with system.add_entities(
            Position(0, 0),
            Velocity(0, 0),
            Acceleration(0, 0),
            ParticleType.SNOW,
            Deposit.AIRBORNE,
            count=self.entity_count,
        ) as created:
            created.run[creation_kernel]()

    def update(mut self, mut system: SystemContext[...]):
        pass
