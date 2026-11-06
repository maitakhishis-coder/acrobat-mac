#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <optional>

namespace focal {
struct Box { double left, bottom, right, top; };
inline Box unite(Box a, Box b) {
    return {std::min(a.left,b.left), std::min(a.bottom,b.bottom),
            std::max(a.right,b.right), std::max(a.top,b.top)};
}
inline bool same(Box a, Box b) {
    return a.left == b.left && a.bottom == b.bottom &&
           a.right == b.right && a.top == b.top;
}
struct Geometry {
    Box media, crop, trim, bleed;
    std::array<double,6> matrix;
    bool transform;
};
// Campos en el orden del cuadro de diálogo: ancho, alto, X, Y, escala X/Y, giro, sangre.
using Settings = std::array<std::optional<double>,8>;
inline Geometry calculate(Box media, Box crop, Box trim, Box bleed,
                          double userUnit, const Settings& fields) {
    const double unit = 72.0 / (25.4 * userUnit);
    const double x = fields[2] ? media.left - *fields[2] * unit : trim.left;
    const double y = fields[3] ? media.bottom - *fields[3] * unit : trim.bottom;
    const double width = fields[0] ? *fields[0] * unit : trim.right - trim.left;
    const double height = fields[1] ? *fields[1] * unit : trim.top - trim.bottom;
    const Box cut{x,y,x+width,y+height};
    const double sx = fields[4].value_or(100) / 100;
    const double sy = fields[5].value_or(100) / 100;
    const double angle = fields[6].value_or(0);
    const double rad = angle * (3.14159265358979323846 / 180.0);
    const double cx = x + width / 2, cy = y + height / 2;
    const double a = sx * std::cos(rad), b = sx * std::sin(rad);
    const double c = -sy * std::sin(rad), d = sy * std::cos(rad);
    const Box newMedia = unite(media, cut);
    if (fields[7]) {
        const double margin = *fields[7] * unit;
        bleed = {std::max(newMedia.left, cut.left-margin),
                 std::max(newMedia.bottom, cut.bottom-margin),
                 std::min(newMedia.right, cut.right+margin),
                 std::min(newMedia.top, cut.top+margin)};
    } else {
        bleed = unite(bleed, cut);
    }
    return {newMedia, unite(crop, cut), cut, bleed,
            {a,b,c,d,cx-a*cx-c*cy,cy-b*cx-d*cy},
            sx != 1 || sy != 1 || std::fmod(angle,360.0) != 0};
}
}
