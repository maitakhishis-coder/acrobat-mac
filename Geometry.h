#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <string>

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
// Evalúa operaciones sencillas: + - * / paréntesis, coma o punto decimal y la unidad
// opcional "mm" (que se ignora). Ejemplo: "122 mm+2" -> 124. Devuelve false si no es válida.
namespace detail {
class Expression {
public:
    explicit Expression(const std::string& text) : s(text) {}
    bool evaluate(double& result) {
        double value = 0;
        if (s.size() > 200 || !sum(value, 0)) return false;
        skip();
        if (pos != s.size() || !std::isfinite(value)) return false;
        result = value;
        return true;
    }
private:
    const std::string& s;
    size_t pos = 0;
    static bool digit(char c) { return c >= '0' && c <= '9'; }
    void skip() { while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\t')) ++pos; }
    bool peek(char c) { skip(); return pos < s.size() && s[pos] == c; }
    bool sum(double& value, int depth) {
        if (!product(value, depth)) return false;
        for (;;) {
            double other = 0;
            if (peek('+')) { ++pos; if (!product(other, depth)) return false; value += other; }
            else if (peek('-')) { ++pos; if (!product(other, depth)) return false; value -= other; }
            else return true;
        }
    }
    bool product(double& value, int depth) {
        if (!unary(value, depth)) return false;
        for (;;) {
            double other = 0;
            if (peek('*')) { ++pos; if (!unary(other, depth)) return false; value *= other; }
            else if (peek('/')) {
                ++pos;
                if (!unary(other, depth) || other == 0) return false;
                value /= other;
            }
            else return true;
        }
    }
    bool unary(double& value, int depth) {
        if (depth > 40) return false;
        if (peek('-')) { ++pos; if (!unary(value, depth + 1)) return false; value = -value; return true; }
        if (peek('+')) { ++pos; return unary(value, depth + 1); }
        return primary(value, depth);
    }
    bool primary(double& value, int depth) {
        if (peek('(')) {
            ++pos;
            if (!sum(value, depth + 1) || !peek(')')) return false;
            ++pos;
            return true;
        }
        return number(value);
    }
    bool number(double& value) {
        skip();
        double whole = 0, fraction = 0, divisor = 1;
        bool digits = false;
        while (pos < s.size() && digit(s[pos])) { whole = whole * 10 + (s[pos++] - '0'); digits = true; }
        if (pos < s.size() && (s[pos] == '.' || s[pos] == ',')) {
            ++pos;
            while (pos < s.size() && digit(s[pos])) {
                fraction = fraction * 10 + (s[pos++] - '0');
                divisor *= 10;
                digits = true;
            }
        }
        if (!digits) return false;
        skip();
        if (pos + 1 < s.size() && (s[pos] == 'm' || s[pos] == 'M') &&
            (s[pos + 1] == 'm' || s[pos + 1] == 'M')) pos += 2;
        value = whole + fraction / divisor;
        return true;
    }
};
}  // namespace detail

inline bool evaluate(const std::string& text, double& result) {
    return detail::Expression(text).evaluate(result);
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
