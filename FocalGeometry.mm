#import <AppKit/AppKit.h>
#include "FocalGeometry.h"
#include <iomanip>
#include <locale>
#include <sstream>
#include <string>
#include <vector>
#include "Geometry.h"

namespace {
using focal::Box;
constexpr double fixedScale = 65536;
AVMenuItem geometryItem, trimItem;
AVExecuteProc editProc, toggleProc;
AVPageViewDrawProc drawProc;
bool showTrim = true;
bool drawingRegistered = false;

Box fromFixed(ASFixedRect rect) {
    return {rect.left/fixedScale, rect.bottom/fixedScale,
            rect.right/fixedScale, rect.top/fixedScale};
}

ASFixedRect toFixed(Box box) {
    ASFixedRect rect{};
    rect.left = static_cast<ASFixed>(std::lround(box.left*fixedScale));
    rect.bottom = static_cast<ASFixed>(std::lround(box.bottom*fixedScale));
    rect.right = static_cast<ASFixed>(std::lround(box.right*fixedScale));
    rect.top = static_cast<ASFixed>(std::lround(box.top*fixedScale));
    return rect;
}

struct Boxes { Box media, crop, trim, bleed; };
Boxes readBoxes(PDPage page) {
    ASFixedRect media{}, crop{}, trim{}, bleed{};
    PDPageGetMediaBox(page, &media);
    PDPageGetCropBox(page, &crop);
    if (!PDPageGetBox(page, ASAtomFromString("TrimBox"), &trim)) trim = crop;
    if (!PDPageGetBox(page, ASAtomFromString("BleedBox"), &bleed)) bleed = crop;
    return {fromFixed(media), fromFixed(crop), fromFixed(trim), fromFixed(bleed)};
}

void redraw(AVPageView view) {
    if (!view) return;
    AVDevRect area{};
    AVPageViewGetAperture(view, &area);
    AVPageViewInvalidateRect(view, &area);
    AVPageViewDrawNow(view);
}

ACCB1 void ACCB2 drawTrim(AVPageView view, AVDevRect*, void*) {
    if (!showTrim || !view) return;
    const PDPageNumber original = AVPageViewGetPageNum(view);
    if (original < 0) return;
    DURING
        PDColorValueRec previous{}, blue{};
        AVPageViewGetColor(view, &previous);
        blue.space = PDDeviceRGB;
        blue.value[1] = static_cast<ASFixed>(0.32 * fixedScale);
        blue.value[2] = ASInt32ToFixed(1);
        AVPageViewSetColor(view, &blue);
        DURING
            const auto first = AVPageViewGetFirstVisiblePageNum(view);
            const auto last = AVPageViewGetLastVisiblePageNum(view);
            for (auto number = first; number >= 0 && number <= last; ++number) {
                if (!AVPageViewPageNumIsVisible(view, number)) continue;
                AVPageViewSetPageNum(view, number);
                PDPage page = AVPageViewGetPage(view);
                if (!page) continue;
                ASFixedRect trim{};
                if (!PDPageGetBox(page, ASAtomFromString("TrimBox"), &trim))
                    PDPageGetCropBox(page, &trim);
                AVDevRect device{};
                AVPageViewRectToDevice(view, &trim, &device);
                AVPageViewDrawRectOutline(view, &device, 2, nullptr, 0);
            }
        HANDLER
            // A view can become invalid while Acrobat is repainting it.
        END_HANDLER
        AVPageViewSetPageNum(view, original);
        AVPageViewSetColor(view, &previous);
    HANDLER
    END_HANDLER
}

ACCB1 void ACCB2 toggleTrim(void*) {
    showTrim = !showTrim;
    if (auto doc = AVAppGetActiveDoc()) redraw(AVDocGetPageView(doc));
}

struct DialogData {
    int current, total;
    std::string summary;
    focal::Settings settings;
    std::vector<int> pages;
};

bool readPages(std::wstring text, int total, std::vector<int>& pages) {
    text.erase(std::remove_if(text.begin(), text.end(), [](wchar_t c) {
        return c == L' ' || c == L'\t';
    }), text.end());
    pages.clear();
    if (text == L"todas" || text == L"pares" || text == L"impares") {
        for (int page = 1; page <= total; ++page)
            if (text == L"todas" || (page % 2 == (text == L"impares" ? 1 : 0)))
                pages.push_back(page - 1);
        return !pages.empty();
    }
    if (text.empty() || text.back() == L',') return false;
    std::wistringstream list(text);
    std::wstring item;
    while (std::getline(list, item, L',')) {
        auto readNumber = [total](const std::wstring& s) {
            int value = 0;
            for (auto c : s) {
                if (c < L'0' || c > L'9' || value > (total - (c-L'0')) / 10)
                    return 0;
                value = 10*value + (c-L'0');
            }
            return value <= total ? value : 0;
        };
        const auto dash = item.find(L'-');
        int first = readNumber(item.substr(0,dash));
        int last = dash == std::wstring::npos ? first : readNumber(item.substr(dash+1));
        if (!first || last < first) return false;
        for (int page = first; page <= last; ++page) pages.push_back(page-1);
    }
    std::sort(pages.begin(), pages.end());
    pages.erase(std::unique(pages.begin(), pages.end()), pages.end());
    return !pages.empty();
}

NSTextField* addField(NSView* view, NSString* label, CGFloat y, CGFloat x, CGFloat width) {
    NSTextField* caption = [NSTextField labelWithString:label];
    caption.frame = NSMakeRect(x, y + 25, width, 19);
    [view addSubview:caption];
    NSTextField* input = [NSTextField textFieldWithString:@""];
    input.frame = NSMakeRect(x, y, width, 22);
    [view addSubview:input];
    return input;
}

bool parseSetting(NSString* text, int index, std::optional<double>& field) {
    const double minimum[] = {.1,.1,-5000,-5000,.1,.1,-360,0};
    const double maximum[] = {5000,5000,5000,5000,1000,1000,360,100};
    std::string value(text.UTF8String);
    field.reset();
    if (value.find_first_not_of(" \t") == std::string::npos) return true;
    std::replace(value.begin(), value.end(), ',', '.');
    std::istringstream stream(value);
    stream.imbue(std::locale::classic());
    double number;
    if (!(stream >> number) || !std::isfinite(number) ||
        number < minimum[index] || number > maximum[index] ||
        !(stream >> std::ws).eof()) return false;
    field = number;
    return true;
}

bool showGeometryDialog(DialogData& data) {
    @autoreleasepool {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"Focal · Geometría de páginas";
        alert.informativeText = [NSString stringWithUTF8String:data.summary.c_str()];
        [alert addButtonWithTitle:@"Aplicar"];
        [alert addButtonWithTitle:@"Cancelar"];
        NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 290)];
        alert.accessoryView = view;
        NSTextField* pages = addField(view, @"Páginas (1, 3-5, pares, impares, todas)", 239, 0, 430);
        pages.stringValue = [NSString stringWithFormat:@"%d", data.current + 1];
        NSString* labels[] = {
            @"Ancho del recorte (mm)", @"Alto del recorte (mm)",
            @"Desplazamiento X (mm)", @"Desplazamiento Y (mm)",
            @"Escala X (%)", @"Escala Y (%)",
            @"Giro adicional (°)", @"Sangre en 4 lados (mm)"
        };
        NSTextField* inputs[8];
        NSView* previous = pages;
        for (int i = 0; i < 8; ++i) {
            inputs[i] = addField(view, labels[i], 186 - 51 * (i / 2), 220 * (i % 2), 210);
            previous.nextKeyView = inputs[i];
            previous = inputs[i];
        }
        previous.nextKeyView = pages;
        NSTextField* hint = [NSTextField labelWithString:
            @"Deja en blanco los valores que quieras conservar."];
        hint.frame = NSMakeRect(0, 5, 430, 18);
        [view addSubview:hint];
        NSString* error = nil;
        for (;;) {
            alert.informativeText = error ?: [NSString stringWithUTF8String:data.summary.c_str()];
            [alert.window setInitialFirstResponder:pages];
            if ([alert runModal] != NSAlertFirstButtonReturn) return false;
            const std::string selection(pages.stringValue.UTF8String);
            if (selection.size() > 1023 ||
                !readPages(std::wstring(selection.begin(), selection.end()), data.total, data.pages)) {
                error = @"Revisa la selección de páginas.";
                continue;
            }
            error = nil;
            bool entered = false;
            for (int i = 0; i < 8; ++i) {
                if (!parseSetting(inputs[i].stringValue, i, data.settings[i])) {
                    error = [NSString stringWithFormat:@"Revisa el valor de %@.", labels[i]];
                    break;
                }
                entered = entered || data.settings[i].has_value();
            }
            if (error) continue;
            if (entered) return true;
            error = @"Introduce al menos un valor.";
        }
    }
}

struct Edit {
    int number;
    Boxes before;
    focal::Geometry after;
    CosObj replacement;
};

bool representable(Box b) {
    return b.right-b.left >= 1/fixedScale && b.top-b.bottom >= 1/fixedScale &&
           b.left >= -32768 && b.bottom >= -32768 && b.right < 32767.99 && b.top < 32767.99;
}

CosObj makeStream(CosDoc doc, const std::string& text) {
    ASStm reader = ASMemStmRdOpen(text.data(), static_cast<ASArraySize>(text.size()));
    CosObj result = CosNewNull();
    DURING
        result = CosNewStream(doc, true, reader, 0, false, CosNewNull(),
                              CosNewNull(), static_cast<CosByteMax>(text.size()));
    HANDLER
        ASStmClose(reader);
        RERAISE();
    END_HANDLER
    ASStmClose(reader);
    return result;
}

CosObj wrapContents(PDPage page, const std::array<double,6>& matrix) {
    const CosObj contents = CosDictGet(PDPageGetCosObj(page), ASAtomFromString("Contents"));
    const auto type = CosObjGetType(contents);
    if (type == CosNull || (type == CosArray && CosArrayLength(contents) == 0))
        return CosNewNull();
    const CosDoc doc = CosObjGetDoc(PDPageGetCosObj(page));
    const auto count = type == CosArray ? CosArrayLength(contents) : 1;
    CosObj array = CosNewArray(doc, false, count+2);
    std::ostringstream prefix;
    prefix.imbue(std::locale::classic());
    prefix << "q\n" << std::fixed << std::setprecision(12);
    for (double value : matrix) prefix << value << ' ';
    prefix << "cm\n";
    CosArrayPut(array, 0, makeStream(doc,prefix.str()));
    for (ASTArraySize i = 0; i < count; ++i)
        CosArrayPut(array, i+1, type == CosArray ? CosArrayGet(contents,i) : contents);
    CosArrayPut(array, count+1, makeStream(doc,"\nQ\n"));
    return array;
}

bool prepareEdit(PDDoc doc, int number, const focal::Settings& settings, Edit& edit) {
    PDPage page = PDDocAcquirePage(doc, number);
    bool valid = false;
    DURING
        auto before = readBoxes(page);
        const double unit = PDPageGetUserUnitSize(page);
        if (std::isfinite(unit) && unit > 0) {
            const auto next = focal::calculate(before.media,before.crop,before.trim,before.bleed,unit,settings);
            valid = representable(next.media) && representable(next.crop) &&
                    representable(next.trim) && representable(next.bleed) &&
                    (!next.transform || PDPageGetNumAnnots(page) == 0);
            if (valid) edit = {number,before,next,CosNewNull()};
        }
    HANDLER
        PDPageRelease(page);
        RERAISE();
    END_HANDLER
    PDPageRelease(page);
    return valid;
}

void prepareContents(PDDoc doc, Edit& edit) {
    if (!edit.after.transform) return;
    PDPage page = PDDocAcquirePage(doc, edit.number);
    DURING
        edit.replacement = wrapContents(page, edit.after.matrix);
    HANDLER
        PDPageRelease(page);
        RERAISE();
    END_HANDLER
    PDPageRelease(page);
}

void applyEdit(PDDoc doc, const Edit& edit) {
    PDPage page = PDDocAcquirePage(doc, edit.number);
    DURING
        const auto& next = edit.after;
        if (!focal::same(next.media,edit.before.media))
            PDPageSetMediaBox(page,toFixed(next.media));
        if (!focal::same(next.crop,edit.before.crop))
            PDPageSetBox(page,ASAtomFromString("CropBox"),toFixed(next.crop));
        if (!focal::same(next.bleed,edit.before.bleed) ||
            !focal::same(next.crop,edit.before.crop))
            PDPageSetBox(page,ASAtomFromString("BleedBox"),toFixed(next.bleed));
        if (!focal::same(next.trim,edit.before.trim) ||
            !focal::same(next.crop,edit.before.crop))
            PDPageSetBox(page,ASAtomFromString("TrimBox"),toFixed(next.trim));
        if (CosObjGetType(edit.replacement) != CosNull)
            PDPageAddCosContents(page,edit.replacement);
    HANDLER
        PDPageRelease(page);
        RERAISE();
    END_HANDLER
    PDPageRelease(page);
}

void openGeometry() {
    const AVDoc doc = AVAppGetActiveDoc();
    if (!doc) return;
    if (!AVDocPermRequest(doc, PDPermReqObjDoc, PDPermReqOprModify)) {
        AVAlertNote("El PDF no permite modificaciones.");
        return;
    }
    const PDDoc pdf = AVDocGetPDDoc(doc);
    const AVPageView view = AVDocGetPageView(doc);
    if (!pdf || !view) return;
    PDPage page = AVPageViewGetPage(view);
    if (!page) return;
    DialogData data{};
    data.current = AVPageViewGetPageNum(view);
    data.total = PDDocGetNumPages(pdf);
    const auto boxes = readBoxes(page);
    const double mm = 25.4 * PDPageGetUserUnitSize(page) / 72.0;
    std::ostringstream summary;
    summary << std::fixed << std::setprecision(2) << "Página " << data.current+1
            << " · Recorte " << (boxes.trim.right-boxes.trim.left)*mm << " × "
            << (boxes.trim.top-boxes.trim.bottom)*mm << " mm\nX "
            << (boxes.media.left-boxes.trim.left)*mm << " mm · Y "
            << (boxes.media.bottom-boxes.trim.bottom)*mm << " mm";
    data.summary = summary.str();
    if (!showGeometryDialog(data) || AVAppGetActiveDoc() != doc) return;

    std::vector<Edit> edits(data.pages.size());
    int invalid = -1;
    bool failed = false;
    DURING
        for (size_t i = 0; i < data.pages.size(); ++i) {
            if (!prepareEdit(pdf,data.pages[i],data.settings,edits[i])) {
                invalid = data.pages[i];
                break;
            }
        }
        if (invalid < 0) {
            for (auto& edit : edits) prepareContents(pdf,edit);
            for (const auto& edit : edits) applyEdit(pdf,edit);
        }
    HANDLER
        failed = true;
    END_HANDLER
    if (failed) {
        AVAlertNote("Acrobat interrumpio el cambio. Cierra la copia de trabajo sin guardar y vuelve a abrirla.");
    } else if (invalid >= 0) {
        const std::string error = "Pagina " + std::to_string(invalid+1) +
            ": medidas fuera de rango o anotaciones incompatibles con escala/giro.";
        AVAlertNote(error.c_str());
    } else {
        showTrim = true;
        redraw(view);
    }
}

ACCB1 void ACCB2 editGeometry(void*) {
    DURING
        openGeometry();
    HANDLER
        AVAlertNote("Acrobat no pudo leer la geometria del PDF.");
    END_HANDLER
}

AVMenuItem addItem(AVMenu menu, ASExtension extension, const char* title,
                   const char* name, AVExecuteProc callback) {
    auto item = AVMenuItemNew(title,name,nullptr,false,NO_SHORTCUT,0,nullptr,extension);
    if (item) {
        AVMenuItemSetExecuteProc(item,callback,nullptr);
        AVMenuAddMenuItem(menu,item,APPEND_MENUITEM);
    }
    return item;
}
}

ASBool FocalUnload() {
    if (drawingRegistered) {
        AVAppUnregisterForPageViewDrawing(drawProc);
        drawingRegistered = false;
    }
    for (AVMenuItem item : {geometryItem,trimItem}) {
        if (item) {
            AVMenuItemRemove(item);
            AVMenuItemRelease(item);
        }
    }
    geometryItem = trimItem = nullptr;
    if (drawProc) ASCallbackDestroy(drawProc);
    if (editProc) ASCallbackDestroy(editProc);
    if (toggleProc) ASCallbackDestroy(toggleProc);
    drawProc = nullptr;
    editProc = toggleProc = nullptr;
    return true;
}

ASBool FocalInit(ASExtension extension) {
    auto menu = AVMenubarAcquireMenuByName(AVAppGetMenubar(),"File");
    if (!menu) return false;
    editProc = ASCallbackCreateProto(AVExecuteProc,&editGeometry);
    toggleProc = ASCallbackCreateProto(AVExecuteProc,&toggleTrim);
    drawProc = ASCallbackCreateProto(AVPageViewDrawProc,&drawTrim);
    geometryItem = addItem(menu,extension,"Focal: Geometria de paginas...",
                           "CEVAGRAF:FocalGeometry",editProc);
    trimItem = addItem(menu,extension,"Focal: Mostrar u ocultar TrimBox azul",
                       "CEVAGRAF:FocalTrim",toggleProc);
    AVMenuRelease(menu);
    if (!geometryItem || !trimItem) {
        FocalUnload();
        return false;
    }
    AVAppRegisterForPageViewDrawing(drawProc,nullptr);
    drawingRegistered = true;
    return true;
}
