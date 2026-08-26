#include "common.glsl"

// Position the origin to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint cells[];
};

vec4 cell_bg() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    bool has_extra_rows = pixel_scroll_offset_y > 0.0;
    int first_row = has_extra_rows ? 1 : 0;
    int last_row = int(grid_size.y) - 1 - (has_extra_rows ? 1 : 0);

    vec2 scrolled_pos = gl_FragCoord.xy;
    scrolled_pos.y += pixel_scroll_offset_y;
    ivec2 grid_pos = ivec2(floor((scrolled_pos - grid_padding.wx) / cell_size));
    int visible_rows = last_row - first_row + 1;
    int unshifted_row = int(floor(
        (gl_FragCoord.y - grid_padding.x) / cell_size.y
    ));
    bool above_grid = unshifted_row < 0;
    bool below_grid = unshifted_row >= visible_rows;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec4 bg = vec4(0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    // Vertical padding extends from the visible viewport edge, never from
    // either extra row. Inside the terminal area, clamp only for safety at
    // the extreme ends of the sub-row offset range.
    if (above_grid) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = first_row;
        } else {
            return bg;
        }
    } else if (below_grid) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = last_row;
        } else {
            return bg;
        }
    } else {
        grid_pos.y = clamp(grid_pos.y, 0, int(grid_size.y) - 1);
    }

    // Load the color for the cell.
    vec4 cell_color = load_color(
            unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x]),
            use_linear_blending
        );

    return cell_color;
}

void main() {
    out_FragColor = cell_bg();
}
