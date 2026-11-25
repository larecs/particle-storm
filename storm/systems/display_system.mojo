"""DisplaySystem: rasterizes particles and shows them in an SDL3 window."""

from std.ffi import external_call
from std.math import cos, pi, sin
from std.memory import ArcPointer
from std.sys import size_of
from std.time import monotonic
from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    System,
    SystemContext,
)
from storm.components import ParticleType, Position
from storm.resources import (
    Bounds,
    Editor,
    Framebuffer,
    Input,
    Obstacles,
    RunState,
)


comptime _Handle = Pointer[UInt8, MutUntrackedOrigin]


comptime SNOW_COLOR = UInt32(0xFFD8EBFF)
"""Packed ARGB8888 snow color."""
comptime SAND_COLOR = UInt32(0xFFDCA657)
"""Packed ARGB8888 sand color."""
comptime _CIRCLE_SEGMENTS = 32
"""Triangles per drawn obstacle."""


@fieldwise_init
struct _Vertex(TrivialRegisterPassable):
    """Matches SDL_Vertex: position, RGBA color, and texture coordinate."""

    var x: Float32
    var y: Float32
    var r: Float32
    var g: Float32
    var b: Float32
    var a: Float32
    var u: Float32
    var v: Float32


@always_inline
def _vertex(
    x: Float32, y: Float32, sx: Float32, sy: Float32, lit: Bool
) -> _Vertex:
    """Creates an obstacle-colored vertex from domain coordinates.

    Args:
        x: X coordinate in meters.
        y: Y coordinate in meters.
        sx: Pixels per meter along x.
        sy: Pixels per meter along y.
        lit: Whether to use the highlight color.

    Returns:
        Vertex in framebuffer pixel coordinates.
    """
    if lit:
        return _Vertex(x * sx, y * sy, 0.43, 0.48, 0.58, 1.0, 0, 0)
    return _Vertex(x * sx, y * sy, 0.24, 0.26, 0.31, 1.0, 0, 0)


def obstacle_vertices(
    obstacles: Obstacles,
    bounds: Bounds,
    width: Int,
    height: Int,
    highlight: Int = -1,
) -> List[_Vertex]:
    """Builds a triangle list that fills every obstacle shape.

    Args:
        obstacles: Obstacles in domain coordinates.
        bounds: Domain size in meters.
        width: Framebuffer width in pixels.
        height: Framebuffer height in pixels.
        highlight: Group drawn in the highlight color, or -1.

    Returns:
        Three vertices per triangle in framebuffer pixel coordinates.
    """
    comptime assert size_of[_Vertex]() == 32, "_Vertex must match SDL_Vertex"
    var vertices = List[_Vertex]()
    var sx = Float32(width) / bounds.width
    var sy = Float32(height) / bounds.height

    for i in range(obstacles.count):
        var cx = obstacles.x[i]
        var cy = obstacles.y[i]
        var hw = obstacles.half_width[i]
        var hh = obstacles.half_height[i]
        var lit = Int(obstacles.group[i]) == highlight
        if obstacles.rectangle[i] != 0:
            var c = obstacles.cos_angle[i]
            var s = obstacles.sin_angle[i]
            var corners = List[_Vertex]()
            for corner in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]:
                corners.append(
                    _vertex(
                        cx + c * corner[0] - s * corner[1],
                        cy + s * corner[0] + c * corner[1],
                        sx,
                        sy,
                        lit,
                    )
                )
            for k in [0, 1, 2, 0, 2, 3]:
                vertices.append(corners[k])
            continue
        for k in range(_CIRCLE_SEGMENTS):
            var a0 = Float32(2 * pi) * Float32(k) / _CIRCLE_SEGMENTS
            var a1 = Float32(2 * pi) * Float32(k + 1) / _CIRCLE_SEGMENTS
            vertices.append(_vertex(cx, cy, sx, sy, lit))
            vertices.append(
                _vertex(cx + cos(a0) * hw, cy + sin(a0) * hw, sx, sy, lit)
            )
            vertices.append(
                _vertex(cx + cos(a1) * hw, cy + sin(a1) * hw, sx, sy, lit)
            )
    return vertices^


def _check(success: Bool, operation: String) raises:
    """Raises an SDL error when a C API operation fails.

    Args:
        success: Whether the SDL operation succeeded.
        operation: Name of the failed operation.

    Raises:
        Error: If success is false, including SDL's diagnostic.
    """
    if not success:
        var message = external_call["SDL_GetError", _Handle]()
        var length = Int(external_call["strlen", UInt](message))
        var text = String(
            from_utf8_lossy=Span(unsafe_ptr=message, length=length)
        )
        raise Error(operation + ": " + text)


def raster_kernel(
    context: KernelContext[
        Filter().read[Position, ParticleType](),
        Resources[]().read[Bounds]().write[Framebuffer](),
    ]
):
    """Plots every particle into a freshly cleared framebuffer.

    Args:
        context: Particle rows, domain bounds, and the framebuffer canvas.
    """
    ref bounds = context.resources.get[Bounds]()
    ref canvas = context.resources.get[Framebuffer]()
    var scale_x = Float32(canvas.width) / bounds.width
    var scale_y = Float32(canvas.height) / bounds.height
    for particle in context:
        ref position = particle.get[Position]()
        var x = min(max(Int(position.x * scale_x), 0), canvas.width - 1)
        var y = min(max(Int(position.y * scale_y), 0), canvas.height - 1)
        var color = (
            SNOW_COLOR if particle.get[ParticleType]().id
            == ParticleType.SNOW.id else SAND_COLOR
        )
        canvas.plot(x, y, color)


struct _Display(Movable):
    """Owns the SDL handles and the frame rate counter."""

    var window: Optional[_Handle]
    var renderer: Optional[_Handle]
    var texture: Optional[_Handle]
    var width: Int
    """Logical render width in pixels."""
    var height: Int
    """Logical render height in pixels."""
    var hud: List[String]
    """Help and status lines drawn at the bottom of the window."""
    var obstacles: List[_Vertex]
    var fps_text: String
    var _fps_frames: Int
    var _fps_started: Int
    var _initialized: Bool

    def __init__(out self):
        """Creates an unopened display."""
        self.window = None
        self.renderer = None
        self.texture = None
        self.width = 1
        self.height = 1
        self.hud = List[String]()
        self.obstacles = List[_Vertex]()
        self.fps_text = "FPS: --"
        self._fps_frames = 0
        self._fps_started = monotonic()
        self._initialized = False

    def __deinit__(deinit self):
        """Releases the texture, renderer, and window before shutting down SDL.
        """
        self.close()

    def close(mut self):
        """Releases SDL handles, including after partial initialization."""
        if self.texture:
            external_call["SDL_DestroyTexture", NoneType](self.texture.value())
            self.texture = None
        if self.renderer:
            external_call["SDL_DestroyRenderer", NoneType](
                self.renderer.value()
            )
            self.renderer = None
        if self.window:
            external_call["SDL_DestroyWindow", NoneType](self.window.value())
            self.window = None
        if self._initialized:
            external_call["SDL_Quit", NoneType]()
            self._initialized = False

    def open(mut self, width: Int, height: Int) raises:
        """Creates a resizable window, a renderer, and a streaming texture.

        Args:
            width: Framebuffer width in pixels.
            height: Framebuffer height in pixels.

        Raises:
            Error: If SDL initialization, window creation, or setup fails.
        """
        if self._initialized:
            raise Error("Display is already open")
        self.width = width
        self.height = height
        external_call["SDL_SetMainReady", NoneType]()
        _check(external_call["SDL_Init", Bool](UInt32(0x20)), "SDL_Init")
        self._initialized = True
        var title = String("Larecs particle storm — Escape to quit")
        self.window = external_call["SDL_CreateWindow", Optional[_Handle]](
            title.as_c_string_slice().unsafe_ptr(),
            Int32(width * 2),
            Int32(height * 2),
            UInt64(0x20),
        )
        _check(Bool(self.window), "SDL_CreateWindow")
        self.renderer = external_call["SDL_CreateRenderer", Optional[_Handle]](
            self.window.value(), Optional[_Handle]()
        )
        _check(Bool(self.renderer), "SDL_CreateRenderer")
        _check(
            external_call["SDL_SetRenderLogicalPresentation", Bool](
                self.renderer.value(), Int32(width), Int32(height), Int32(2)
            ),
            "SDL_SetRenderLogicalPresentation",
        )
        # Unsupported vsync is harmless; TimeSystem also caps the frame rate.
        _ = external_call["SDL_SetRenderVSync", Bool](
            self.renderer.value(), Int32(1)
        )
        # SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING
        self.texture = external_call["SDL_CreateTexture", Optional[_Handle]](
            self.renderer.value(),
            UInt32(0x16362004),
            Int32(1),
            Int32(width),
            Int32(height),
        )
        _check(Bool(self.texture), "SDL_CreateTexture")
        # SDL_SCALEMODE_NEAREST keeps particles crisp when the window scales.
        _check(
            external_call["SDL_SetTextureScaleMode", Bool](
                self.texture.value(), Int32(0)
            ),
            "SDL_SetTextureScaleMode",
        )

    def count_frame(mut self):
        """Counts one frame and refreshes the FPS label twice per second."""
        self._fps_frames += 1
        var now = monotonic()
        var seconds = Float64(now - self._fps_started) * 1e-9
        if seconds >= 0.5:
            var fps = Float64(self._fps_frames) / seconds
            self.fps_text = "FPS: " + String(Int(fps + 0.5))
            self._fps_frames = 0
            self._fps_started = now

    def poll_events(mut self, mut input: Input, bounds: Bounds) -> Bool:
        """Drains SDL events into `input` and checks for quit requests.

        Args:
            input: Receives this frame's mouse and keyboard input.
            bounds: Domain size, for converting the cursor to meters.

        Returns:
            False after a quit event or while Escape is held, otherwise True.
        """
        input = Input()
        # SDL_Event is a 128-byte union with at least pointer alignment.
        var event = Array[UInt64, 16](fill=0)
        var words = event.unsafe_ptr().unsafe_bitcast[UInt32]()
        var bytes = event.unsafe_ptr().unsafe_bitcast[UInt8]()
        var running = True
        while external_call["SDL_PollEvent", Bool](event.unsafe_ptr()):
            var kind = words[unsafe_offset=0]
            if kind == 0x100:  # SDL_EVENT_QUIT
                running = False
            elif (
                kind == 0x300 and bytes[unsafe_offset=37] == 0
            ):  # SDL_EVENT_KEY_DOWN
                var scancode = words[unsafe_offset=6]
                if scancode == 30:  # 1
                    input.tool = 1
                elif scancode == 31:  # 2
                    input.tool = 2
                elif scancode == 76 or scancode == 42:  # Delete, Backspace
                    input.delete_pressed = True
            elif kind == 0x401:  # SDL_EVENT_MOUSE_BUTTON_DOWN
                if bytes[unsafe_offset=24] == 1:
                    input.left_pressed = True
                elif bytes[unsafe_offset=24] == 3:
                    input.right_pressed = True
            elif kind == 0x403:  # SDL_EVENT_MOUSE_WHEEL
                input.wheel += event.unsafe_ptr().unsafe_bitcast[Float32]()[
                    unsafe_offset=7
                ]

        var window_x: Float32 = 0
        var window_y: Float32 = 0
        var buttons = external_call["SDL_GetMouseState", UInt32](
            Pointer(to=window_x), Pointer(to=window_y)
        )
        input.left_down = (buttons & 1) != 0
        var x: Float32 = -1
        var y: Float32 = -1
        if self.renderer:
            _ = external_call["SDL_RenderCoordinatesFromWindow", Bool](
                self.renderer.value(),
                window_x,
                window_y,
                Pointer(to=x),
                Pointer(to=y),
            )
        input.over_domain = (
            x >= 0
            and y >= 0
            and x < Float32(self.width)
            and y < Float32(self.height)
        )
        input.mouse = Position(
            x * bounds.width / Float32(self.width),
            y * bounds.height / Float32(self.height),
        )
        var keys = external_call["SDL_GetKeyboardState", _Handle](
            Optional[Pointer[Int32, MutUntrackedOrigin]]()
        )
        if keys[unsafe_offset=20] != 0:  # Q
            input.rotation -= 1
        if keys[unsafe_offset=8] != 0:  # E
            input.rotation += 1
        return running and keys[unsafe_offset=41] == 0

    def draw(mut self, framebuffer: Framebuffer) raises:
        """Uploads the framebuffer, draws it with obstacles, the FPS label, and
        the HUD lines, and presents.

        Args:
            framebuffer: Rasterized image matching the texture size.

        Raises:
            Error: If uploading, drawing, or presenting fails.
        """
        var renderer = self.renderer.value()
        _check(
            external_call["SDL_UpdateTexture", Bool](
                self.texture.value(),
                Optional[_Handle](),
                framebuffer.pixels.unsafe_ptr(),
                Int32(framebuffer.width * 4),
            ),
            "SDL_UpdateTexture",
        )
        _check(
            external_call["SDL_RenderTexture", Bool](
                renderer,
                self.texture.value(),
                Optional[_Handle](),
                Optional[_Handle](),
            ),
            "SDL_RenderTexture",
        )
        if len(self.obstacles):
            _check(
                external_call["SDL_RenderGeometry", Bool](
                    renderer,
                    Optional[_Handle](),
                    self.obstacles.unsafe_ptr(),
                    Int32(len(self.obstacles)),
                    Optional[_Handle](),
                    Int32(0),
                ),
                "SDL_RenderGeometry",
            )
        _check(
            external_call["SDL_SetRenderDrawColor", Bool](
                renderer, UInt8(255), UInt8(255), UInt8(255), UInt8(255)
            ),
            "SDL_SetRenderDrawColor",
        )
        _check(
            external_call["SDL_RenderDebugText", Bool](
                renderer,
                Float32(4),
                Float32(4),
                self.fps_text.as_c_string_slice().unsafe_ptr(),
            ),
            "SDL_RenderDebugText",
        )
        # SDL's debug font is 8 pixels tall; stack lines above the bottom.
        for i in range(len(self.hud)):
            var y = self.height - 10 * (len(self.hud) - i) - 2
            _check(
                external_call["SDL_RenderDebugText", Bool](
                    renderer,
                    Float32(4),
                    Float32(y),
                    self.hud[i].as_c_string_slice().unsafe_ptr(),
                ),
                "SDL_RenderDebugText",
            )
        _check(
            external_call["SDL_RenderPresent", Bool](renderer),
            "SDL_RenderPresent",
        )


struct DisplaySystem[backend: ExecutionBackend = ExecutionBackend.HOST](System):
    """Rasterizes particles with a kernel and shows the image on the main thread.

    Parameters:
        backend: HOST (threaded) or DEVICE execution for rasterization.
    """

    var _display: ArcPointer[_Display]

    def __init__(out self):
        """Creates shared ownership so system copies cannot double-free SDL."""
        self._display = ArcPointer(_Display())

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Adds a Framebuffer resource if missing and opens the SDL display.

        Args:
            context: The scheduler's world context.

        Raises:
            Error: If opening the SDL display fails.
        """
        if not context.world[].resources.has[Framebuffer]():
            context.world[].resources.add(Framebuffer())
        ref framebuffer = context.world[].resources.read[Framebuffer]()
        self._display[].open(framebuffer.width, framebuffer.height)

    def update(mut self, mut context: SystemContext[...]) raises:
        """Rasterizes particles and draws a frame with obstacles and FPS label.

        Args:
            context: World containing particles, bounds, the framebuffer, and
                the run state.

        Raises:
            Error: If rasterizing or rendering fails.
        """
        ref display = self._display[]
        ref resources = context.world[].resources
        var input = Input()
        var running = display.poll_events(input, resources.read[Bounds]())
        if resources.has[Input]():
            resources.set(input^)
        if not running:
            resources.get[RunState]().running = False
            return
        comptime if Self.backend == ExecutionBackend.DEVICE:
            context.run[raster_kernel, backend=Self.backend]()
        else:
            context.run[raster_kernel, backend=ExecutionBackend.HOST_THREADED]()
        ref framebuffer = context.world[].resources.read[Framebuffer]()
        var highlight = -1
        display.hud.clear()
        if resources.has[Editor]():
            ref editor = resources.read[Editor]()
            highlight = editor.hovered
            display.hud.append(
                String(
                    "tool: ",
                    "rectangle" if editor.tool == 1 else "circle",
                    "   [1] circle  [2] rectangle",
                )
            )
            display.hud.append(
                "click: add/drag  wheel: size  Q/E: rotate  right: delete"
            )
            if editor.message:
                display.hud.append(editor.message)
        # Obstacles may move, so their geometry follows the packed resource.
        if resources.has[Obstacles]():
            display.obstacles = obstacle_vertices(
                resources.read[Obstacles](),
                resources.read[Bounds](),
                framebuffer.width,
                framebuffer.height,
                highlight,
            )
        display.count_frame()
        display.draw(framebuffer)

    def finalize(mut self, mut context: SystemContext[...]):
        """Closes the display when the scheduler finishes.

        Args:
            context: The scheduler's world context.
        """
        self._display[].close()
