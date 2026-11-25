"""Checks the storm vortex, wind deflection, and obstacle collisions."""

from std.math import pi, sqrt
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_true,
)
from larecs import Filter, SystemContext, World
from storm.components import Obstacle, Position, Velocity
from storm.periodic import wrap_delta
from storm.resources import Bounds, MAX_OBSTACLES, Obstacles, Storm, Wind
from storm.scene import ObstacleBuilder
from storm.systems import ObstacleSystem


def main() raises:
    """Runs the weather checks.

    Raises:
        Error: If a check fails.
    """
    var bounds = Bounds()
    assert_almost_equal(wrap_delta(110, 120), -10)
    assert_almost_equal(wrap_delta(-70, 120), 50)

    # Tangential speed peaks at max_speed on the core radius, across the seam
    # too, with inflow pointing back toward the center.
    var storm = Storm(radius=10, max_speed=20, inflow=0.5)
    # In a huge domain the taper is negligible near the core.
    var huge = Bounds(100_000, 100_000)
    var wind = storm.wind(Position(5, 0), Position(99_995, 0), huge)
    assert_almost_equal(wind.dx, -10, atol=1e-4)
    assert_almost_equal(wind.dy, 20, atol=1e-4)
    var far = storm.wind(Position(15, 0), Position(99_995, 0), huge)
    assert_true(abs(far.dy) < 20)
    # Half a domain from the center the tapered wind vanishes.
    var seam = storm.wind(Position(60, 37.5), Position(0, 37.5), bounds)
    assert_almost_equal(seam.dx, 0, atol=1e-5)
    assert_almost_equal(seam.dy, 0, atol=1e-5)

    var obstacles = Obstacles()
    obstacles.add(Position(60, 37.5), Obstacle.circle(5))
    # Inside an obstacle there is no wind.
    var inside = obstacles.deflect(Wind(10, 0), Position(61, 37.5), bounds)
    assert_equal(inside.dx, 0)
    assert_equal(inside.dy, 0)
    # Flow hitting the surface head-on loses its normal component.
    var front = obstacles.deflect(Wind(10, 0), Position(54.999, 37.5), bounds)
    assert_almost_equal(front.dx, 0, atol=1e-2)
    # Flow passing the side speeds up to twice the free-stream speed.
    var side = obstacles.deflect(Wind(10, 0), Position(60, 32.499), bounds)
    assert_almost_equal(side.dx, 20, atol=1e-2)
    # Beyond four radii the wind is unchanged.
    var away = obstacles.deflect(Wind(10, 0), Position(60, 15), bounds)
    assert_equal(away.dx, 10)

    # A particle inside is pushed to the surface and stops moving inward.
    var position = Position(57, 37.5)
    var velocity = Velocity(10, 4)
    assert_true(obstacles.collide(position, velocity, bounds))
    var dx = position.x - 60
    var dy = position.y - 37.5
    assert_almost_equal(sqrt(dx * dx + dy * dy), 5, atol=1e-4)
    assert_almost_equal(velocity.dx, 0, atol=1e-5)
    assert_almost_equal(velocity.dy, 4 * obstacles.friction, atol=1e-5)

    try:
        for _ in range(MAX_OBSTACLES):
            obstacles.add(Position(0, 0), Obstacle.circle(1))
        raise Error("expected capacity error")
    except e:
        assert_true("At most" in String(e))

    check_rectangles()
    check_builder()
    check_obstacle_system()
    print(
        "PASS: vortex, taper, wrapping, circles, rotated rectangles, builder,"
        " capacity, obstacle entities"
    )


def check_obstacle_system() raises:
    """Checks that ObstacleSystem mirrors obstacle entities into the resource.

    Raises:
        Error: If a check fails.
    """
    var world = World[Position, Velocity, Obstacle]()
    var big = world.storage.add_entity(Position(60, 37.5), Obstacle.circle(8))
    var small = world.storage.add_entity(Position(10, 10), Obstacle.circle(2))
    # Particles without an Obstacle component are not packed.
    _ = world.storage.add_entity(Position(1, 1), Velocity(0, 0))
    var context = SystemContext(world)
    var system = ObstacleSystem()
    system.initialize(context)
    ref packed = context.world[].resources.read[Obstacles]()
    assert_equal(packed.count, 2)
    assert_equal(packed.half_width.reduce_add(), 10)

    # Moving an obstacle entity updates the resource on the next frame.
    context.world[].storage.get[Position](big).x = 70
    system.update(context)
    ref moved = context.world[].resources.read[Obstacles]()
    assert_true(moved.x.eq(70).reduce_or(), "moved obstacle center not packed")
    assert_false(moved.x.eq(60).reduce_or())

    context.world[].storage.remove_entity(small)
    system.update(context)
    assert_equal(context.world[].resources.read[Obstacles]().count, 1)

    for _ in range(MAX_OBSTACLES):
        _ = context.world[].storage.add_entity(
            Position(0, 0), Obstacle.circle(1)
        )
    try:
        system.update(context)
        raise Error("expected capacity error")
    except e:
        assert_true("At most" in String(e))


def check_rectangles() raises:
    """Checks wind and collisions against axis-aligned and rotated rectangles.

    Raises:
        Error: If a check fails.
    """
    var bounds = Bounds()
    # 10 m wide and 4 m tall: faces at x = 55 and 65, y = 35.5 and 39.5.
    var flat = Obstacles()
    flat.add(Position(60, 37.5), Obstacle.rectangle(10, 4))
    var inside = flat.deflect(Wind(10, 0), Position(64, 38), bounds)
    assert_equal(inside.dx, 0)
    var front = flat.deflect(Wind(10, 0), Position(54.999, 37.5), bounds)
    assert_almost_equal(front.dx, 0, atol=1e-2)
    # Flow along the long top face speeds up instead of being blocked.
    var above = flat.deflect(Wind(10, 0), Position(60, 35.499), bounds)
    assert_almost_equal(above.dx, 20, atol=1e-2)

    # Closest to the top face: pushed up, inward speed removed.
    var position = Position(60.5, 37)
    var velocity = Velocity(3, 5)
    _ = flat.collide(position, velocity, bounds)
    assert_almost_equal(position.x, 60.5, atol=1e-5)
    assert_almost_equal(position.y, 35.5, atol=1e-5)
    assert_almost_equal(velocity.dx, 3 * flat.friction, atol=1e-5)
    assert_almost_equal(velocity.dy, 0, atol=1e-5)

    # Rotated by 90 degrees it is 4 m wide, so its right face is at x = 62.
    var upright = Obstacles()
    upright.add(Position(60, 37.5), Obstacle.rectangle(10, 4, Float32(pi / 2)))
    position = Position(61.5, 37.5)
    velocity = Velocity(0, 0)
    _ = upright.collide(position, velocity, bounds)
    assert_almost_equal(position.x, 62, atol=1e-4)
    assert_almost_equal(position.y, 37.5, atol=1e-4)
    # The old right face at x = 65 is now open space.
    position = Position(64, 37.5)
    _ = upright.collide(position, velocity, bounds)
    assert_almost_equal(position.x, 64, atol=1e-5)

    try:
        flat.add(Position(0, 0), Obstacle.rectangle(0, 1))
        raise Error("expected size error")
    except e:
        assert_true("positive" in String(e))


def check_builder() raises:
    """Checks that the builder rotates parts around its origin and spawns them.

    Raises:
        Error: If a check fails.
    """
    var world = World[Position, Obstacle]()
    var spawned = (
        ObstacleBuilder(10, 20, angle=Float32(pi / 2))
        .rectangle(4, 0, width=2, height=1, angle=0.25)
        .circle(0, 0, radius=1)
        .spawn(world)
    )
    # The first group in a world without obstacles is 1.
    assert_equal(spawned, 1)
    var found = 0
    for entity in world.storage.query[Filter().read[Position, Obstacle]()]():
        ref position = entity.get[Position]()
        ref obstacle = entity.get[Obstacle]()
        assert_equal(obstacle.group, 1)
        if obstacle.shape == Obstacle.RECTANGLE:
            # The local offset (4, 0) turns to (0, 4); angles add up.
            assert_almost_equal(position.x, 10, atol=1e-5)
            assert_almost_equal(position.y, 24, atol=1e-5)
            assert_almost_equal(obstacle.angle, Float32(pi / 2) + 0.25)
            assert_equal(obstacle.half_width, 1)
            assert_equal(obstacle.half_height, 0.5)
        else:
            assert_equal(position.x, 10)
            assert_equal(position.y, 20)
        found += 1
    assert_equal(found, 2)

    try:
        _ = ObstacleBuilder(0, 0).spawn(world)
        raise Error("expected empty builder error")
    except e:
        assert_true("at least one shape" in String(e))
    try:
        _ = ObstacleBuilder(0, 0).circle(0, 0, radius=-1)
        raise Error("expected size error")
    except e:
        assert_true("positive" in String(e))
