#include "Geometry.h"
#include <cassert>

using namespace focal;

int main() {
    const Box media{-30,-20,570,780}, crop{-20,-10,560,770};
    const Box trim{0,10,500,710}, bleed{-10,0,510,720};
    Settings fields{};
    const auto original = calculate(media,crop,trim,bleed,1,fields);
    assert(same(original.media,media) && same(original.crop,crop));
    assert(same(original.trim,trim) && same(original.bleed,bleed) && !original.transform);

    fields[2] = 25.4;
    fields[3] = -25.4;
    fields[0] = 50.8;
    fields[1] = 101.6;
    fields[7] = 3;
    const auto expanded = calculate(media,crop,trim,bleed,2,fields);
    assert(same(expanded.trim,{-66,16,6,160}));
    assert(expanded.media.left == -66 && expanded.crop.left == -66);
    assert(expanded.bleed.left == -66);
    assert(std::abs(expanded.bleed.right-(6+3*72.0/50.8)) < 1e-10);

    fields = {};
    fields[4] = 80;
    fields[5] = 110;
    fields[6] = 90;
    const auto scaled = calculate(media,crop,trim,bleed,1,fields);
    const auto m = scaled.matrix;
    assert(scaled.transform && same(scaled.trim,trim));
    assert(std::abs(m[0]*250+m[2]*360+m[4]-250) < 1e-10);
    assert(std::abs(m[1]*250+m[3]*360+m[5]-360) < 1e-10);
    assert(std::abs(m[1]-.8) < 1e-10 && std::abs(m[2]+1.1) < 1e-10);
}
