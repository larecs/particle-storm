"""Particle kind component."""


@fieldwise_init
struct ParticleType(TrivialRegisterPassable):
    """Index selecting a particle's response time and display color."""

    var id: Int

    comptime SNOW = Self(id=0)
    comptime SAND = Self(id=1)
