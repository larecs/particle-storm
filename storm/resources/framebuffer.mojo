"""Framebuffer resource that kernels rasterize into on the host or a device."""

from larecs import (
    AtomicView,
    DevicePassableResource,
    ResourceAccess,
    ResourceAdapter,
    ResourceDeviceCache,
)


comptime BACKGROUND = UInt32(0xFF080C14)
"""Packed ARGB8888 color of empty pixels."""


@fieldwise_init
struct FramebufferPixels(TrivialRegisterPassable):
    """Read view over packed ARGB8888 pixels."""

    var pixels: Pointer[UInt32, ImmUntrackedOrigin]
    var width: Int
    var height: Int


@fieldwise_init
struct FramebufferCanvas(TrivialRegisterPassable):
    """Writer view over packed ARGB8888 pixels."""

    var pixels: Pointer[UInt32, MutUntrackedOrigin]
    var width: Int
    var height: Int

    @always_inline
    def plot(self, x: Int, y: Int, color: UInt32):
        """Sets one pixel; concurrent writers to a pixel race benignly.

        Args:
            x: Column in `[0, width)`.
            y: Row in `[0, height)`.
            color: Packed ARGB8888 color.
        """
        AtomicView[True, UInt32, MutUntrackedOrigin](
            unsafe_pointer=Pointer(
                to=self.pixels[unsafe_offset=y * self.width + x]
            )
        ).store(color)


struct Framebuffer(DevicePassableResource):
    """Owns a row-major image of packed ARGB8888 pixels."""

    comptime Adapter = FramebufferAdapter
    var width: Int
    var height: Int
    var pixels: List[UInt32]

    def __init__(out self, width: Int = 640, height: Int = 400):
        """Creates a framebuffer filled with the background color.

        Args:
            width: Image width in pixels.
            height: Image height in pixels.
        """
        self.width = width
        self.height = height
        self.pixels = List[UInt32](length=width * height, fill=BACKGROUND)


struct FramebufferAdapter(ResourceAdapter):
    """Selects FramebufferPixels for `read` and FramebufferCanvas otherwise.

    `write` access starts every run from a cleared background image.
    """

    comptime Source = Framebuffer
    comptime View[mutable: Bool] = (
        FramebufferCanvas if mutable else FramebufferPixels
    )
    comptime supports_mutation = True
    # Pixels are written with atomic stores.
    comptime supports_concurrent_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks that the pixel count matches the dimensions.

        Args:
            source: Current framebuffer.

        Raises:
            Error: If the pixel buffer does not match width times height.
        """
        if len(source.pixels) != source.width * source.height:
            raise Error("Framebuffer pixels do not match its dimensions")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows host pixels for reading.

        Args:
            source: Validated framebuffer.

        Raises:
            Error: Never.

        Returns:
            Read view over host pixels.
        """
        return {
            Pointer[UInt32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.pixels.unsafe_ptr())
            ),
            source.width,
            source.height,
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads pixels for a read view.

        Args:
            source: Validated framebuffer.
            cache: Leased cache.

        Raises:
            Error: If the upload fails.

        Returns:
            Read view over device pixels.
        """
        return {
            cache.upload[UInt32](0, Span(source.pixels)),
            source.width,
            source.height,
        }

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Clears pixels for `write`, then borrows them.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Validated framebuffer.

        Raises:
            Error: Never.

        Returns:
            Writer view over host pixels.
        """
        comptime if not access.preserves_contents():
            for ref pixel in source.pixels:
                pixel = BACKGROUND
        return {
            Pointer[UInt32, MutUntrackedOrigin](
                unsafe_from_address=Int(source.pixels.unsafe_ptr())
            ),
            source.width,
            source.height,
        }

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Clears or uploads device pixels.

        Parameters:
            access: `WRITE` clears to the background; `READ_WRITE` uploads.

        Args:
            source: Validated framebuffer.
            cache: Leased cache on the world's device queue.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Writer view over device pixels.
        """
        comptime if access.preserves_contents():
            return {
                cache.upload_mutable[UInt32](0, Span(source.pixels)),
                source.width,
                source.height,
            }
        else:
            return {
                cache.fill[UInt32](0, len(source.pixels), BACKGROUND),
                source.width,
                source.height,
            }

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Stages the rendered image for publication after completion.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Framebuffer receiving the image.
            cache: Cache holding this invocation's buffers.

        Raises:
            Error: If staging fails.
        """
        cache.download(0, Span(source.pixels))

    @staticmethod
    def finalize[access: ResourceAccess](mut source: Self.Source) raises:
        """Leaves published pixels unchanged.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Framebuffer holding published pixels.

        Raises:
            Error: Never.
        """
        pass
