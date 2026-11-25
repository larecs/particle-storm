"""Headless SDL checks for rasterization, fresh frames, quit, and cleanup."""

from std.ffi import external_call
from std.sys import has_accelerator
from std.testing import assert_equal, assert_false, assert_true
from larecs import ExecutionBackend, SystemContext, World
from storm.components import ParticleType, Position
from storm.resources import BACKGROUND, Bounds, Framebuffer, Input, RunState
from storm.systems import DisplaySystem
from storm.systems.display_system import SAND_COLOR, SNOW_COLOR


def count_lit(framebuffer: Framebuffer) -> Int:
    """Counts pixels that differ from the background.

    Args:
        framebuffer: Rasterized image.

    Returns:
        Number of non-background pixels.
    """
    var lit = 0
    for pixel in framebuffer.pixels:
        if pixel != BACKGROUND:
            lit += 1
    return lit


def push_event(kind: UInt32, word: Int, value: UInt32) raises:
    """Pushes an SDL event with one 32-bit payload word set.

    Bytes 24 and onward hold the button index for mouse button events, so
    word 6 also sets the button.

    Args:
        kind: SDL event type.
        word: Index of the 32-bit word to set.
        value: Raw bits of the word.

    Raises:
        Error: If SDL rejects the event.
    """
    var event = Array[UInt64, 16](fill=0)
    var words = event.unsafe_ptr().unsafe_bitcast[UInt32]()
    words[unsafe_offset=0] = kind
    words[unsafe_offset=word] = value
    assert_true(external_call["SDL_PushEvent", Bool](event.unsafe_ptr()))


def check_backend[backend: ExecutionBackend]() raises:
    """Verifies rasterization, cleared frames, quit, and cleanup on a backend.

    Parameters:
        backend: Execution backend for the raster kernel.

    Raises:
        Error: If SDL setup, drawing, or an assertion fails.
    """
    var world = World[Position, ParticleType]()
    world.resources.add(Bounds())
    world.resources.add(RunState())
    world.resources.add(Input())
    var snow = world.storage.add_entity(Position(60, 37.5), ParticleType.SNOW)
    _ = world.storage.add_entity(Position(30, 18.75), ParticleType.SAND)
    # An archetype without a particle type must not be drawn.
    _ = world.storage.add_entity(Position(0, 0))
    var context = SystemContext(world)
    var display = DisplaySystem[backend]()
    display.initialize(context)
    display.update(context)
    ref image = context.world[].resources.read[Framebuffer]()
    assert_equal(image.pixels[200 * 640 + 320], SNOW_COLOR)
    assert_equal(image.pixels[100 * 640 + 160], SAND_COLOR)
    assert_equal(count_lit(image), 2)
    assert_true(display._display[].fps_text.startswith("FPS: "))

    # Copies share ownership; each frame starts from a cleared image.
    var copied = display.copy()
    context.world[].storage.get[Position](snow).x = 15
    copied.update(context)
    ref moved = context.world[].resources.read[Framebuffer]()
    assert_equal(moved.pixels[200 * 640 + 80], SNOW_COLOR)
    assert_equal(moved.pixels[200 * 640 + 320], BACKGROUND)
    assert_equal(count_lit(moved), 2)

    # Editor input: key 2, a right click, and two wheel notches.
    push_event(0x300, 6, UInt32(31))
    push_event(0x401, 6, UInt32(3))
    push_event(0x403, 7, UInt32(0x40000000))  # Float32 2.0
    display.update(context)
    ref input = context.world[].resources.read[Input]()
    assert_equal(input.tool, 2)
    assert_true(input.right_pressed)
    assert_false(input.left_pressed)
    assert_equal(input.wheel, 2)
    # Edge flags last one frame.
    display.update(context)
    ref idle = context.world[].resources.read[Input]()
    assert_equal(idle.tool, 0)
    assert_false(idle.right_pressed)
    assert_equal(idle.wheel, 0)

    var event = Array[UInt64, 16](fill=0)
    event.unsafe_ptr().unsafe_bitcast[UInt32]()[] = 0x100
    assert_true(external_call["SDL_PushEvent", Bool](event.unsafe_ptr()))
    display.update(context)
    assert_false(context.world[].resources.get[RunState]().running)
    display.finalize(context)
    assert_false(Bool(copied._display[].window))
    assert_false(Bool(copied._display[].renderer))
    assert_false(Bool(copied._display[].texture))
    # Cleanup is safe when called again or when shared owners are destroyed.
    copied.finalize(context)


def main() raises:
    """Runs the display checks on the host and, if available, a device.

    Raises:
        Error: If a check fails.
    """
    check_backend[ExecutionBackend.HOST_THREADED]()
    comptime if has_accelerator():
        check_backend[ExecutionBackend.DEVICE]()
    print(
        "PASS: rasterization, cleared frames, FPS label, editor input, quit,"
        " cleanup"
    )
