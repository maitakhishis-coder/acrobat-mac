#import <AppKit/AppKit.h>
#include <dlfcn.h>
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

void redrawActive() {
    const AVDoc doc = AVAppGetActiveDoc();
    if (!doc) return;
    DURING
        redraw(AVDocGetPageView(doc));
    HANDLER
    END_HANDLER
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

// Aplica los ajustes a las páginas indicadas del PDF activo.
// Devuelve "" si todo fue bien o un mensaje de error (UTF-8).
std::string applyGeometry(const std::string& selection, const focal::Settings& settings, int& count) {
    count = 0;
    const AVDoc doc = AVAppGetActiveDoc();
    if (!doc) return "No hay ningún PDF abierto.";
    PDDoc pdf = nullptr;
    AVPageView view = nullptr;
    int total = 0, current = -1;
    bool permitted = false, unreadable = false;
    DURING
        permitted = AVDocPermRequest(doc, PDPermReqObjDoc, PDPermReqOprModify);
        pdf = AVDocGetPDDoc(doc);
        view = AVDocGetPageView(doc);
        if (pdf) total = PDDocGetNumPages(pdf);
        if (view) current = AVPageViewGetPageNum(view);
    HANDLER
        unreadable = true;
    END_HANDLER
    if (unreadable || !pdf || !view) return "Acrobat no pudo leer la geometría del PDF.";
    if (!permitted) return "El PDF no permite modificaciones.";

    std::vector<int> pages;
    if (selection == "actual") {
        if (current < 0 || current >= total) return "Acrobat no pudo identificar la página actual.";
        pages.push_back(current);
    } else if (selection.size() > 1023 ||
               !readPages(std::wstring(selection.begin(), selection.end()), total, pages)) {
        return "Revisa la selección de páginas.";
    }

    std::vector<Edit> edits(pages.size());
    int invalid = -1;
    bool failed = false;
    DURING
        for (size_t i = 0; i < pages.size(); ++i) {
            if (!prepareEdit(pdf,pages[i],settings,edits[i])) {
                invalid = pages[i];
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
    if (failed)
        return "Acrobat interrumpió el cambio. Cierra la copia de trabajo sin guardar y vuelve a abrirla.";
    if (invalid >= 0)
        return "Página " + std::to_string(invalid+1) +
               ": medidas fuera de rango o anotaciones incompatibles con escala/giro.";
    showTrim = true;
    DURING
        redraw(view);
    HANDLER
    END_HANDLER
    count = static_cast<int>(pages.size());
    return {};
}

// Geometría actual de la página visible, en milímetros.
struct PageInfo {
    bool ok = false;
    AVDoc doc = nullptr;
    int number = 0, total = 0;
    double width = 0, height = 0, x = 0, y = 0, bleed = 0;
    bool hasBleed = false;
};

PageInfo readPageInfo() {
    PageInfo info;
    info.doc = AVAppGetActiveDoc();
    if (!info.doc) return info;
    DURING
        const AVPageView view = AVDocGetPageView(info.doc);
        const PDDoc pdf = AVDocGetPDDoc(info.doc);
        PDPage page = view ? AVPageViewGetPage(view) : nullptr;
        if (page && pdf) {
            const auto boxes = readBoxes(page);
            const double mm = 25.4 * PDPageGetUserUnitSize(page) / 72.0;
            info.number = AVPageViewGetPageNum(view);
            info.total = PDDocGetNumPages(pdf);
            info.width = (boxes.trim.right - boxes.trim.left) * mm;
            info.height = (boxes.trim.top - boxes.trim.bottom) * mm;
            info.x = (boxes.media.left - boxes.trim.left) * mm;
            info.y = (boxes.media.bottom - boxes.trim.bottom) * mm;
            const double l = boxes.trim.left - boxes.bleed.left;
            const double b = boxes.trim.bottom - boxes.bleed.bottom;
            const double r = boxes.bleed.right - boxes.trim.right;
            const double t = boxes.bleed.top - boxes.trim.top;
            const double eps = 1e-3;
            info.hasBleed = l >= 0 && std::fabs(l-b) < eps && std::fabs(l-r) < eps &&
                            std::fabs(l-t) < eps;
            info.bleed = l * mm;
            info.ok = true;
        }
    HANDLER
        info.ok = false;
    END_HANDLER
    return info;
}

NSString* numberText(double value) {
    if (std::fabs(value) < 0.005) value = 0;
    return [NSString stringWithFormat:@"%.2f", value];
}

NSString* const kLabels[8] = {
    @"Ancho del recorte (mm)", @"Alto del recorte (mm)",
    @"Desplazamiento X (mm)", @"Desplazamiento Y (mm)",
    @"Escala X (%)", @"Escala Y (%)",
    @"Giro adicional (°)", @"Sangre en 4 lados (mm)"
};
}  // namespace

// Panel no modal: se queda abierto después de aplicar los cambios.
@interface FocalPanelController : NSObject <NSWindowDelegate>
@property (strong) NSPanel* panel;
@property (strong) NSTextField* summary;
@property (strong) NSTextField* status;
@property (strong) NSTextField* range;
@property (strong) NSButton* trimCheck;
@property (strong) NSArray<NSButton*>* modes;
@property (strong) NSArray<NSTextField*>* inputs;
@property (strong) NSArray<NSString*>* initial;
@property (strong) NSTimer* timer;
@property (assign) AVDoc lastDoc;
@property (assign) int lastPage;
@property (assign) BOOL positioned;
- (void)show;
- (void)shutdown;
@end

@implementation FocalPanelController

- (NSImage*)loadLogo {
    NSBundle* bundle = [NSBundle bundleForClass:[FocalPanelController class]];
    NSImage* logo = [bundle imageForResource:@"FocalLogo"];
    if (logo) return logo;
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&FocalInit), &info) && info.dli_fname) {
        NSString* binary = [NSString stringWithUTF8String:info.dli_fname];
        NSString* root = [[[binary stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString* path = [root stringByAppendingPathComponent:@"Contents/Resources/FocalLogo.png"];
        return [[NSImage alloc] initWithContentsOfFile:path];
    }
    return nil;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    const CGFloat width = 470, height = 472;
    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.title = @"Focal Geometry";
    panel.floatingPanel = YES;
    panel.hidesOnDeactivate = YES;
    panel.releasedWhenClosed = NO;
    panel.delegate = self;
    NSView* content = panel.contentView;

    // Cabecera: logo, título y resumen de la página
    CGFloat textX = 20;
    NSImage* logo = [self loadLogo];
    if (logo) {
        NSImageView* imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 408, 56, 56)];
        imageView.image = logo;
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        [content addSubview:imageView];
        textX = 86;
    }
    NSTextField* heading = [NSTextField labelWithString:@"Focal · Geometría de páginas"];
    heading.font = [NSFont boldSystemFontOfSize:15];
    heading.frame = NSMakeRect(textX, 442, width - textX - 20, 22);
    [content addSubview:heading];
    self.summary = [NSTextField labelWithString:@""];
    self.summary.frame = NSMakeRect(textX, 414, width - textX - 20, 20);
    [content addSubview:self.summary];

    NSView* fields = [[NSView alloc] initWithFrame:NSMakeRect(20, 96, 430, 305)];
    [content addSubview:fields];

    // Selección de páginas: opciones rápidas + rango personalizado
    NSTextField* applyTo = [NSTextField labelWithString:@"Aplicar a:"];
    applyTo.frame = NSMakeRect(0, 285, 430, 17);
    [fields addSubview:applyTo];
    NSString* modeTitles[4] = {@"Esta página", @"Todas", @"Pares", @"Impares"};
    const CGFloat modeX[4] = {0, 118, 200, 282};
    const CGFloat modeW[4] = {115, 78, 78, 100};
    NSMutableArray<NSButton*>* modes = [NSMutableArray array];
    for (int i = 0; i < 4; ++i) {
        NSButton* radio = [NSButton radioButtonWithTitle:modeTitles[i]
                                                  target:self
                                                  action:@selector(modeChanged:)];
        radio.frame = NSMakeRect(modeX[i], 260, modeW[i], 22);
        radio.tag = i;
        [fields addSubview:radio];
        [modes addObject:radio];
    }
    NSButton* rangeRadio = [NSButton radioButtonWithTitle:@"Rango:"
                                                   target:self
                                                   action:@selector(modeChanged:)];
    rangeRadio.frame = NSMakeRect(0, 234, 72, 22);
    rangeRadio.tag = 4;
    [fields addSubview:rangeRadio];
    [modes addObject:rangeRadio];
    modes[0].state = NSControlStateValueOn;
    NSTextField* range = [NSTextField textFieldWithString:@""];
    range.frame = NSMakeRect(76, 234, 354, 22);
    range.placeholderString = @"Ejemplo: 1, 3-5, 8";
    range.enabled = NO;
    [fields addSubview:range];

    // Medidas
    NSMutableArray<NSTextField*>* inputs = [NSMutableArray array];
    NSMutableArray<NSString*>* initial = [NSMutableArray array];
    NSView* previous = nil;
    for (int i = 0; i < 8; ++i) {
        NSTextField* input = addField(fields, kLabels[i], 186 - 51 * (i / 2), 220 * (i % 2), 210);
        if (previous) previous.nextKeyView = input;
        previous = input;
        [inputs addObject:input];
        [initial addObject:@""];
    }
    previous.nextKeyView = range;
    range.nextKeyView = inputs[0];
    NSTextField* hint = [NSTextField labelWithString:
        @"Se muestra la geometría actual; solo se aplican los valores que cambies."];
    hint.frame = NSMakeRect(0, 5, 430, 18);
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor secondaryLabelColor];
    [fields addSubview:hint];

    // Guía azul del TrimBox
    NSButton* trim = [NSButton checkboxWithTitle:@"Mostrar guía azul del TrimBox en el visor"
                                          target:self
                                          action:@selector(trimToggled:)];
    trim.frame = NSMakeRect(20, 68, 430, 20);
    trim.state = showTrim ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:trim];

    self.status = [NSTextField labelWithString:@""];
    self.status.frame = NSMakeRect(20, 44, 430, 18);
    [content addSubview:self.status];

    NSButton* reload = [NSButton buttonWithTitle:@"Actualizar" target:self action:@selector(reloadPressed:)];
    reload.frame = NSMakeRect(20, 10, 100, 28);
    [content addSubview:reload];
    NSButton* apply = [NSButton buttonWithTitle:@"Aplicar" target:self action:@selector(applyPressed:)];
    apply.frame = NSMakeRect(262, 10, 90, 28);
    apply.keyEquivalent = @"\r";
    [content addSubview:apply];
    NSButton* close = [NSButton buttonWithTitle:@"Cerrar" target:self action:@selector(closePressed:)];
    close.frame = NSMakeRect(360, 10, 90, 28);
    close.keyEquivalent = @"\033";
    [content addSubview:close];
    panel.defaultButtonCell = (NSButtonCell*)apply.cell;
    [panel setInitialFirstResponder:inputs[0]];

    self.panel = panel;
    self.range = range;
    self.trimCheck = trim;
    self.modes = modes;
    self.inputs = inputs;
    self.initial = initial;
    self.lastPage = -1;
    return self;
}

- (void)say:(NSString*)message color:(NSColor*)color {
    self.status.stringValue = message;
    self.status.textColor = color;
}

- (void)report:(NSString*)message failed:(BOOL)failed {
    [self say:message color:(failed ? [NSColor systemRedColor] : [NSColor systemGreenColor])];
}

- (void)showSummary:(const PageInfo&)info {
    self.summary.stringValue = [NSString stringWithFormat:@"Página %d de %d · Recorte %@ × %@ mm",
        info.number + 1, info.total, numberText(info.width), numberText(info.height)];
}

- (BOOL)isDirty {
    for (int i = 0; i < 8; ++i)
        if (![self.inputs[i].stringValue isEqualToString:self.initial[i]]) return YES;
    return NO;
}

- (void)syncTrim {
    const NSControlStateValue wanted = showTrim ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.trimCheck.state != wanted) self.trimCheck.state = wanted;
}

- (void)refreshFromPage {
    const PageInfo info = readPageInfo();
    NSMutableArray<NSString*>* initial = [NSMutableArray array];
    if (!info.ok) {
        self.summary.stringValue = @"Abre un PDF para ver su geometría.";
        for (int i = 0; i < 8; ++i) {
            self.inputs[i].stringValue = @"";
            [initial addObject:@""];
        }
        self.initial = initial;
        self.lastDoc = info.doc;
        self.lastPage = -1;
        return;
    }
    NSString* values[8] = {
        numberText(info.width), numberText(info.height),
        numberText(info.x), numberText(info.y),
        @"100", @"100", @"0",
        info.hasBleed ? numberText(info.bleed) : @""
    };
    for (int i = 0; i < 8; ++i) {
        self.inputs[i].stringValue = values[i];
        [initial addObject:values[i]];
    }
    self.initial = initial;
    [self showSummary:info];
    self.lastDoc = info.doc;
    self.lastPage = info.number;
}

- (void)show {
    [self refreshFromPage];
    [self syncTrim];
    [self report:@"" failed:NO];
    if (!self.positioned) {
        [self.panel center];
        self.positioned = YES;
    }
    [self.panel makeKeyAndOrderFront:nil];
    if (!self.timer)
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self
                                                    selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)shutdown {
    [self.timer invalidate];
    self.timer = nil;
    [self.panel close];
}

// Vigila cambios de documento o de página para mantener los valores al día.
- (void)tick:(NSTimer*)timer {
    if (!self.panel.isVisible) return;
    [self syncTrim];
    const PageInfo info = readPageInfo();
    const int page = info.ok ? info.number : -1;
    if (info.doc == self.lastDoc && page == self.lastPage) return;
    if (info.ok && self.lastPage >= 0 && [self isDirty]) {
        // Hay cambios sin aplicar: no se pisan los valores escritos.
        self.lastDoc = info.doc;
        self.lastPage = page;
        [self showSummary:info];
        [self say:@"La página ha cambiado. Pulsa Actualizar para cargar sus valores."
            color:[NSColor secondaryLabelColor]];
        return;
    }
    [self refreshFromPage];
    [self say:@"" color:[NSColor secondaryLabelColor]];
}

- (std::string)pageSelection {
    static const char* const keys[4] = {"actual", "todas", "pares", "impares"};
    for (int i = 0; i < 4; ++i)
        if (self.modes[i].state == NSControlStateValueOn) return keys[i];
    return std::string(self.range.stringValue.UTF8String);
}

- (void)modeChanged:(NSButton*)sender {
    const BOOL custom = sender.tag == 4;
    self.range.enabled = custom;
    if (custom) [self.panel makeFirstResponder:self.range];
}

- (void)trimToggled:(NSButton*)sender {
    showTrim = sender.state == NSControlStateValueOn;
    redrawActive();
}

- (void)applyPressed:(id)sender {
    focal::Settings settings{};
    bool changed = false;
    for (int i = 0; i < 8; ++i) {
        NSString* text = self.inputs[i].stringValue;
        if ([text isEqualToString:self.initial[i]]) continue;
        if (!parseSetting(text, i, settings[i])) {
            [self report:[NSString stringWithFormat:@"Revisa el valor de %@.", kLabels[i]] failed:YES];
            return;
        }
        changed = changed || settings[i].has_value();
    }
    if (!changed) {
        [self report:@"No has cambiado ningún valor." failed:YES];
        return;
    }
    int count = 0;
    const std::string error = applyGeometry([self pageSelection], settings, count);
    if (!error.empty()) {
        [self report:[NSString stringWithUTF8String:error.c_str()] failed:YES];
        return;
    }
    [self refreshFromPage];
    [self syncTrim];
    [self report:[NSString stringWithFormat:@"Cambios aplicados a %d página%@.",
                  count, count == 1 ? @"" : @"s"] failed:NO];
}

- (void)reloadPressed:(id)sender {
    [self refreshFromPage];
    [self report:@"" failed:NO];
}

- (void)closePressed:(id)sender {
    [self.panel close];
}

- (void)windowWillClose:(NSNotification*)notification {
    [self.timer invalidate];
    self.timer = nil;
}

@end

namespace {
FocalPanelController* panelController = nil;

void openGeometry() {
    if (!AVAppGetActiveDoc()) return;
    if (!panelController) panelController = [[FocalPanelController alloc] init];
    [panelController show];
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
    if (panelController) {
        [panelController shutdown];
        panelController = nil;
    }
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
    if (drawProc) ASCallbackDestroy(reinterpret_cast<ASCallback>(drawProc));
    if (editProc) ASCallbackDestroy(reinterpret_cast<ASCallback>(editProc));
    if (toggleProc) ASCallbackDestroy(reinterpret_cast<ASCallback>(toggleProc));
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
