//! Represents a single terminal grid.
const Grid = @This();

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Atlas = @import("Atlas.zig");
const FontAtlas = @import("FontAtlas.zig");
const Terminal = @import("terminal/Terminal.zig");
const gl = @import("opengl.zig");
const gb = @import("gb_math.zig");

const log = std.log.scoped(.grid);

alloc: std.mem.Allocator,

/// Current dimensions for this grid.
size: GridSize,

/// Current cell dimensions for this grid.
cell_size: CellSize,

/// The current set of cells to render.
cells: std.ArrayListUnmanaged(GPUCell),

/// Shader program for cell rendering.
program: gl.Program,
vao: gl.VertexArray,
ebo: gl.Buffer,
vbo: gl.Buffer,

/// The raw structure that maps directly to the buffer sent to the vertex shader.
const GPUCell = struct {
    /// vec2 grid_coord
    grid_col: u16,
    grid_row: u16,

    /// vec4 bg_color_in
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    bg_a: u8,
};

pub fn init(alloc: Allocator) !Grid {
    // Initialize our font atlas. We will initially populate the
    // font atlas with all the visible ASCII characters since they are common.
    var atlas = try Atlas.init(alloc, 512);
    defer atlas.deinit(alloc);
    var font = try FontAtlas.init(atlas);
    defer font.deinit(alloc);
    try font.loadFaceFromMemory(face_ttf, 30);

    // Load all visible ASCII characters and build our cell width based on
    // the widest character that we see.
    const cell_width: f32 = cell_width: {
        var cell_width: f32 = 0;
        var i: u8 = 32;
        while (i <= 126) : (i += 1) {
            const glyph = try font.addGlyph(alloc, i);
            if (glyph.advance_x > cell_width) {
                cell_width = @ceil(glyph.advance_x);
            }
        }

        break :cell_width cell_width;
    };

    // The cell height is the vertical height required to render underscore
    // '_' which should live at the bottom of a cell.
    const cell_height: f32 = cell_height: {
        // TODO(render): kitty does a calculation based on other font
        // metrics that we probably want to research more. For now, this is
        // fine.
        assert(font.ft_face != null);
        const glyph = font.getGlyph('_').?;
        var res: i32 = font.ft_face.*.ascender >> 6;
        res -= glyph.offset_y;
        res += @intCast(i32, glyph.height);
        break :cell_height @intToFloat(f32, res);
    };
    log.debug("cell dimensions w={d} h={d}", .{ cell_width, cell_height });

    // Create our shader
    const program = try gl.Program.createVF(
        @embedFile("../shaders/cell.v.glsl"),
        @embedFile("../shaders/cell.f.glsl"),
    );

    // Set our cell dimensions
    const pbind = try program.use();
    defer pbind.unbind();
    try program.setUniform("cell_size", @Vector(2, f32){ cell_width, cell_height });

    // Setup our VAO
    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    try vao.bind();
    defer gl.VertexArray.unbind() catch null;

    // Element buffer (EBO)
    const ebo = try gl.Buffer.create();
    errdefer ebo.destroy();
    var ebobind = try ebo.bind(.ElementArrayBuffer);
    defer ebobind.unbind();
    try ebobind.setData([6]u8{
        0, 1, 3, // Top-left triangle
        1, 2, 3, // Bottom-right triangle
    }, .StaticDraw);

    // Vertex buffer (VBO)
    const vbo = try gl.Buffer.create();
    errdefer vbo.destroy();
    var vbobind = try vbo.bind(.ArrayBuffer);
    defer vbobind.unbind();
    var offset: usize = 0;
    try vbobind.attributeAdvanced(0, 2, gl.c.GL_UNSIGNED_SHORT, false, @sizeOf(GPUCell), offset);
    offset += 2 * @sizeOf(u16);
    try vbobind.attributeAdvanced(1, 4, gl.c.GL_UNSIGNED_BYTE, false, @sizeOf(GPUCell), offset);
    try vbobind.enableAttribArray(0);
    try vbobind.enableAttribArray(1);
    try vbobind.attributeDivisor(0, 1);
    try vbobind.attributeDivisor(1, 1);

    return Grid{
        .alloc = alloc,
        .cells = .{},
        .cell_size = .{ .width = cell_width, .height = cell_height },
        .size = .{ .rows = 0, .columns = 0 },
        .program = program,
        .vao = vao,
        .ebo = ebo,
        .vbo = vbo,
    };
}

pub fn deinit(self: *Grid) void {
    self.vbo.destroy();
    self.ebo.destroy();
    self.vao.destroy();
    self.program.destroy();
    self.cells.deinit(self.alloc);
    self.* = undefined;
}

/// TODO: remove, this is for testing
pub fn demoCells(self: *Grid) !void {
    self.cells.clearRetainingCapacity();
    try self.cells.ensureUnusedCapacity(self.alloc, self.size.columns * self.size.rows);

    var row: u32 = 0;
    while (row < self.size.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < self.size.columns) : (col += 1) {
            self.cells.appendAssumeCapacity(.{
                .grid_col = @intCast(u16, col),
                .grid_row = @intCast(u16, row),
                .bg_r = @intCast(u8, @mod(col * row, 255)),
                .bg_g = @intCast(u8, @mod(col, 255)),
                .bg_b = @intCast(u8, 255 - @mod(col, 255)),
                .bg_a = 255,
            });
        }
    }
}

/// updateCells updates our GPU cells from the current terminal view.
/// The updated cells will take effect on the next render.
pub fn updateCells(self: *Grid, term: Terminal) !void {
    _ = self;
    _ = term;
}

/// Set the screen size for rendering. This will update the projection
/// used for the shader so that the scaling of the grid is correct.
pub fn setScreenSize(self: *Grid, dim: ScreenSize) !void {
    // Create a 2D orthographic projection matrix with the full width/height.
    var projection: gb.gbMat4 = undefined;
    gb.gb_mat4_ortho2d(
        &projection,
        0,
        @intToFloat(f32, dim.width),
        @intToFloat(f32, dim.height),
        0,
    );

    // Update the projection uniform within our shader
    const bind = try self.program.use();
    defer bind.unbind();
    try self.program.setUniform("projection", projection);

    // Recalculate the rows/columns.
    self.size.update(dim, self.cell_size);

    log.debug("screen size screen={} grid={}", .{ dim, self.size });
}

pub fn render(self: Grid) !void {
    // If we have no cells to render, then we render nothing.
    if (self.cells.items.len == 0) return;

    const pbind = try self.program.use();
    defer pbind.unbind();

    // Setup our VAO
    try self.vao.bind();
    defer gl.VertexArray.unbind() catch null;

    // Bind EBO
    var ebobind = try self.ebo.bind(.ElementArrayBuffer);
    defer ebobind.unbind();

    // Bind VBO and set data
    var binding = try self.vbo.bind(.ArrayBuffer);
    defer binding.unbind();
    try binding.setData(self.cells.items, .StaticDraw);

    try gl.drawElementsInstanced(
        gl.c.GL_TRIANGLES,
        6,
        gl.c.GL_UNSIGNED_BYTE,
        self.cells.items.len,
    );
}

/// The dimensions of a single "cell" in the terminal grid.
///
/// The dimensions are dependent on the current loaded set of font glyphs.
/// We calculate the width based on the widest character and the height based
/// on the height requirement for an underscore (the "lowest" -- visually --
/// character).
///
/// The units for the width and height are in world space. They have to
/// be normalized using the screen projection.
///
/// TODO(mitchellh): we should recalculate cell dimensions when new glyphs
/// are loaded.
const CellSize = struct {
    width: f32,
    height: f32,
};

/// The dimensions of the screen that the grid is rendered to. This is the
/// terminal screen, so it is likely a subset of the window size. The dimensions
/// should be in pixels.
const ScreenSize = struct {
    width: u32,
    height: u32,
};

/// The dimensions of the grid itself, in rows/columns units.
const GridSize = struct {
    const Unit = u32;

    columns: Unit = 0,
    rows: Unit = 0,

    /// Update the columns/rows for the grid based on the given screen and
    /// cell size.
    fn update(self: *GridSize, screen: ScreenSize, cell: CellSize) void {
        self.columns = @floatToInt(Unit, @intToFloat(f32, screen.width) / cell.width);
        self.rows = @floatToInt(Unit, @intToFloat(f32, screen.height) / cell.height);
    }
};

test "GridSize update exact" {
    var grid: GridSize = .{};
    grid.update(.{
        .width = 100,
        .height = 40,
    }, .{
        .width = 5,
        .height = 10,
    });

    try testing.expectEqual(@as(GridSize.Unit, 20), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 4), grid.rows);
}

test "GridSize update rounding" {
    var grid: GridSize = .{};
    grid.update(.{
        .width = 20,
        .height = 40,
    }, .{
        .width = 6,
        .height = 15,
    });

    try testing.expectEqual(@as(GridSize.Unit, 3), grid.columns);
    try testing.expectEqual(@as(GridSize.Unit, 2), grid.rows);
}

const face_ttf = @embedFile("../fonts/FiraCode-Regular.ttf");
