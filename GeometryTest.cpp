#include "Geometry.h"
#include <cassert>
#include <string>

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

    // Operaciones en los campos numéricos
    auto eval = [](const char* text, double& out) { return evaluate(text, out); };
    double r = 0;
    assert(eval("122 mm+2", r) && std::abs(r - 124) < 1e-12);
    assert(eval("210-5,5", r) && std::abs(r - 204.5) < 1e-12);
    assert(eval("(297-6)/2", r) && std::abs(r - 145.5) < 1e-12);
    assert(eval("-7,41", r) && std::abs(r + 7.41) < 1e-12);
    assert(eval("2*3+4", r) && r == 10);
    assert(eval("2+3*4", r) && r == 14);
    assert(eval("10/4", r) && r == 2.5);
    assert(eval("12 + -3", r) && r == 9);
    assert(eval("((2))", r) && r == 2);
    assert(eval(" 7 ", r) && r == 7);
    assert(eval("1,5+1,5", r) && r == 3);
    assert(eval("5 MM", r) && r == 5);
    assert(!eval("10/0", r));
    assert(!eval("abc", r));
    assert(!eval("", r));
    assert(!eval("1+", r));
    assert(!eval("1.5.2", r));
    assert(!eval("5 mm mm", r));
    assert(!eval("(2", r));
    assert(!eval("2)", r));
    assert(!eval(std::string(300, '1').c_str(), r));
    assert(!eval(std::string(100, '-').append("1").c_str(), r));
}
