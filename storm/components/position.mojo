"""Center of a particle or obstacle component."""


@fieldwise_init
struct Position(TrivialRegisterPassable):
    """Particle or obstacle center in meters, with positive y pointing down."""

    var x: Float32
    var y: Float32
