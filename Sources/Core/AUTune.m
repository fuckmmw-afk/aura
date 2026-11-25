#import "AUTune.h"

@implementation AUTuneItem
@end

@implementation AUTuneSection
@end

static AUTuneItem *item(NSString *name, NSString *title, NSString *subtitle, double fallback, double minimum, double maximum,
                        double step, AUTuneFormat format, AUTuneEffect effect) {
    AUTuneItem *i = [AUTuneItem new];
    i.name = name;
    i.title = title;
    i.subtitle = subtitle;
    i.fallback = fallback;
    i.minimum = minimum;
    i.maximum = maximum;
    i.step = step;
    i.format = format;
    i.effect = effect;
    return i;
}

static AUTuneSection *section(NSString *title, NSString *footer, NSArray *items) {
    AUTuneSection *s = [AUTuneSection new];
    s.title = title;
    s.footer = footer;
    s.items = items;
    return s;
}

NSArray<AUTuneSection *> *AUTuneSections(void) {
    static NSArray *sections;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sections = @[
            section(@"Камера и глубина", @"Сразу. Сцена — объёмная модель обложки; при наклоне телефона камера поворачивается вокруг середины.", @[
                item(@"adaptive", @"Подстройка под обложку", @"Крупный план лица — меньше поворот и рельеф, плоская картинка/коллаж — меньше глубины и без поиска мелких объектов", 1, 0, 1, 1, AUTuneSwitch, AUTuneLive),
                item(@"swing", @"Размах поворота", @"Угол камеры при полном наклоне", 14, 3, 35, 0.5, AUTuneDegrees, AUTuneLive),
                item(@"deep", @"Глубина сцены", @"Насколько далеко за обложкой дальний фон", 0.42, 0.05, 1.2, 0.01, AUTunePlain, AUTuneLive),
                item(@"window", @"Плоскость окна", @"0% — фон в плоскости обложки (всё выходит вперёд), 100% — ближний объект в ней (всё уходит вглубь)", 0.70, 0, 1, 0.01, AUTunePercent, AUTuneLive),
                item(@"focal", @"Перспектива", @"Дистанция камеры: меньше — сильнее перспектива", 1.8, 0.6, 6, 0.1, AUTunePlain, AUTuneLive),
                item(@"relief", @"Объём объектов", @"Рельеф внутри объекта по его глубине; 0 — плоские слои", 0.6, 0, 2.5, 0.05, AUTuneTimes, AUTuneLive),
                item(@"reliefFront", @"Выступ рельефа", @"Насколько часть объекта может выступать вперёд", 0.08, 0.01, 0.25, 0.01, AUTunePlain, AUTuneLive),
                item(@"reliefBack", @"Утопание рельефа", @"Насколько часть объекта может уходить назад", 0.03, 0, 0.2, 0.01, AUTunePlain, AUTuneLive),
                item(@"zFar", @"Предел дали", nil, 0.5, 0.1, 2, 0.05, AUTunePlain, AUTuneLive),
                item(@"zNear", @"Предел близи", nil, 0.25, 0.05, 1, 0.05, AUTunePlain, AUTuneLive),
                item(@"zoom", @"Запас зума", @"Обложка чуть увеличена, чтобы при повороте не было видно края", 0.07, 0, 0.3, 0.005, AUTunePercent, AUTuneLive),
            ]),
            section(@"Гироскоп", @"Сразу.", @[
                item(@"tiltFull", @"Наклон до упора", @"Насколько наклонить телефон для полного поворота (изменение гравитации)", 0.15, 0.04, 0.5, 0.01, AUTunePlain, AUTuneLive),
                item(@"follow", @"Возврат к центру", @"За сколько секунд положение, в котором держишь телефон, становится «ровным»", 6, 0.5, 30, 0.5, AUTuneSeconds, AUTuneLive),
                item(@"smooth", @"Плавность", @"Сглаживание движения", 0.05, 0.005, 0.4, 0.005, AUTuneSeconds, AUTuneLive),
                item(@"wake", @"Порог движения", @"Насколько повернуть телефон, чтобы сцена ожила (меньше — чаще перерисовка, теплее)", 0.012, 0.002, 0.05, 0.001, AUTunePlain, AUTuneLive),
                item(@"appFps", @"Кадров в секунду", @"При перегреве — не больше 30", 60, 24, 120, 1, AUTuneCount, AUTuneLive),
                item(@"appScale", @"Чёткость сцены", @"Пикселей на точку: 3 — как экран, 2 — заметно холоднее", 2, 1, 3, 0.25, AUTunePlain, AUTuneLive),
                item(@"invertX", @"Инвертировать по горизонтали", nil, 0, 0, 1, 1, AUTuneSwitch, AUTuneLive),
                item(@"invertY", @"Инвертировать по вертикали", nil, 0, 0, 1, 1, AUTuneSwitch, AUTuneLive),
            ]),
            section(@"Плеер (Fill)", @"Сразу. Доли — от высоты экрана.", @[
                item(@"fillCrop", @"Размер обложки", @"Ширина обложки относительно экрана (больше — крупнее и обрезаны бока)", 1.12, 1, 2, 0.01, AUTuneTimes, AUTuneLive),
                item(@"blur1From", @"Лёгкий блюр: начало", nil, 0.56, 0.2, 1.2, 0.01, AUTunePercent, AUTuneLive),
                item(@"blur1To", @"Лёгкий блюр: полностью", nil, 0.70, 0.2, 1.2, 0.01, AUTunePercent, AUTuneLive),
                item(@"blur1Size", @"Лёгкий блюр: сила", @"Радиус в процентах ширины", 1.2, 0, 6, 0.1, AUTunePlain, AUTuneLive),
                item(@"blur2From", @"Сильный блюр: начало", nil, 0.64, 0.2, 1.2, 0.01, AUTunePercent, AUTuneLive),
                item(@"blur2To", @"Сильный блюр: полностью", nil, 0.84, 0.2, 1.2, 0.01, AUTunePercent, AUTuneLive),
                item(@"blur2Size", @"Сильный блюр: сила", @"Радиус в процентах ширины", 2.0, 0, 12, 0.1, AUTunePlain, AUTuneLive),
                item(@"fadeFrom", @"Затухание: начало", @"Где картинка начинает уходить в цвет плеера", 0.68, 0.2, 1.2, 0.01, AUTunePercent, AUTuneLive),
                item(@"fadeTo", @"Затухание: конец", nil, 0.94, 0.2, 1.3, 0.01, AUTunePercent, AUTuneLive),
            ]),
            section(@"Экран блокировки", @"Клип собирается заново (несколько секунд).", @[
                item(@"lockBoost", @"Размах облёта", @"Относительно плеера", 1.5, 0.2, 4, 0.1, AUTuneTimes, AUTuneLock),
                item(@"orbitX", @"Орбита по горизонтали", nil, 1.0, 0, 1.5, 0.05, AUTunePlain, AUTuneLock),
                item(@"orbitY", @"Орбита по вертикали", nil, 0.7, 0, 1.5, 0.05, AUTunePlain, AUTuneLock),
                item(@"loop", @"Длина круга", nil, 6, 2, 16, 0.5, AUTuneSeconds, AUTuneLock),
                item(@"fps", @"Кадров в секунду", nil, 24, 15, 60, 1, AUTuneCount, AUTuneLock),
                item(@"lockBlurFrom", @"Блюр: начало", @"Доля высоты кадра", 0.74, 0.3, 1, 0.01, AUTunePercent, AUTuneLock),
                item(@"lockBlurTo", @"Блюр: полностью", nil, 1.0, 0.4, 1.3, 0.01, AUTunePercent, AUTuneLock),
                item(@"lockBlur", @"Сила блюра", nil, 1.0, 0, 4, 0.1, AUTuneTimes, AUTuneLock),
                item(@"lockShade", @"Тень под кнопками", nil, 0.28, 0, 0.8, 0.01, AUTunePercent, AUTuneLock),
                item(@"lockShadeHeight", @"Высота тени", nil, 0.28, 0.05, 0.8, 0.01, AUTunePercent, AUTuneLock),
                item(@"lockBitrate", @"Битрейт", @"Мбит/с", 3.5, 1, 15, 0.5, AUTunePlain, AUTuneLock),
            ]),
            section(@"Объекты", @"Сцены собираются заново.", @[
                item(@"sam", @"Искать все объекты (SAM)", @"Каждая овечка, дерево, стул — отдельный слой", 1, 0, 1, 1, AUTuneSwitch, AUTuneScene),
                item(@"maxObjects", @"Максимум объектов", nil, 16, 1, 24, 1, AUTuneCount, AUTuneScene),
                item(@"samGrid", @"Точек поиска", @"Сетка N×N по обложке: больше — мельче объекты, дольше", 8, 3, 16, 1, AUTuneCount, AUTuneScene),
                item(@"samScore", @"Уверенность модели", nil, 0.65, 0.3, 0.98, 0.01, AUTunePercent, AUTuneScene),
                item(@"samStability", @"Стабильность маски", nil, 0.80, 0.3, 0.99, 0.01, AUTunePercent, AUTuneScene),
                item(@"samContrast", @"Выступ по глубине", @"Насколько объект должен быть ближе своего окружения; 0 — брать всё", 0.04, 0, 0.3, 0.005, AUTunePlain, AUTuneScene),
                item(@"samMinArea", @"Минимальный размер", nil, 0.003, 0.0005, 0.05, 0.0005, AUTunePercent, AUTuneScene),
                item(@"samMaxArea", @"Максимальный размер", nil, 0.30, 0.05, 0.8, 0.01, AUTunePercent, AUTuneScene),
                item(@"visionObjects", @"Объекты Vision", @"Люди и главный объект от системы", 6, 0, 12, 1, AUTuneCount, AUTuneScene),
                item(@"depthSplit", @"Делить группы по глубине", @"Двух людей одним куском — на два слоя", 1, 0, 1, 1, AUTuneSwitch, AUTuneScene),
                item(@"edgeSoft", @"Мягкость краёв", @"Радиус в процентах стороны", 0.9, 0, 4, 0.1, AUTunePlain, AUTuneScene),
                item(@"edgePull", @"Подрезка краёв", @"Насколько края объекта поджаты внутрь", 0.3, 0, 2, 0.05, AUTunePlain, AUTuneScene),
                item(@"holeGrow", @"Запас под дорисовку", @"На сколько дорисовываемая область шире объекта (% стороны)", 3.1, 0.5, 10, 0.1, AUTunePlain, AUTuneScene),
                item(@"reliefSmooth", @"Сглаживание рельефа", @"Радиус в процентах стороны: больше — объекты гладче, меньше растяжений", 6.2, 0.5, 20, 0.1, AUTunePlain, AUTuneScene),
                item(@"extension", @"Дорисовка вниз", @"Сколько картинки LaMa дорисовывает под обложкой (доля стороны); 0 — не дорисовывать", 0.5, 0, 0.6, 0.01, AUTunePercent, AUTuneScene),
            ]),
        ];
    });
    return sections;
}

static AUTuneItem *find(NSString *name) {
    static NSDictionary<NSString *, AUTuneItem *> *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        for (AUTuneSection *s in AUTuneSections()) for (AUTuneItem *i in s.items) all[i.name] = i;
        items = all;
    });
    return items[name];
}

static NSString *keyOf(NSString *name) {
    return [@"aura.t." stringByAppendingString:name];
}

double AUTune(NSString *name) {
    AUTuneItem *i = find(name);
    if (!i) return 0;
    id value = [NSUserDefaults.standardUserDefaults objectForKey:keyOf(name)];
    double v = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : i.fallback;
    return MAX(i.minimum, MIN(i.maximum, v));
}

BOOL AUTuneOn(NSString *name) {
    return AUTune(name) >= 0.5;
}

void AUTuneSet(NSString *name, double value) {
    [NSUserDefaults.standardUserDefaults setObject:@(value) forKey:keyOf(name)];
}

void AUTuneResetAll(void) {
    for (AUTuneSection *s in AUTuneSections()) {
        for (AUTuneItem *i in s.items) [NSUserDefaults.standardUserDefaults removeObjectForKey:keyOf(i.name)];
    }
}

NSString *AUTuneSignature(AUTuneEffect effect) {
    NSMutableArray *parts = [NSMutableArray array];
    for (AUTuneSection *s in AUTuneSections()) {
        for (AUTuneItem *i in s.items) {
            // The lock clip is drawn by the camera too: its numbers count for it.
            BOOL counts = i.effect == effect || (effect == AUTuneLock && i.effect == AUTuneLive && ![s.title hasPrefix:@"Плеер"]
                                                 && ![s.title hasPrefix:@"Гироскоп"]);
            if (counts) [parts addObject:[NSString stringWithFormat:@"%g", AUTune(i.name)]];
        }
    }
    return [parts componentsJoinedByString:@","];
}

NSString *AUTuneText(AUTuneItem *i, double v) {
    switch (i.format) {
        case AUTuneTimes: return [NSString stringWithFormat:@"×%.2f", v];
        case AUTunePercent: return v < 0.1 && i.step < 0.01 ? [NSString stringWithFormat:@"%.2f%%", v * 100] : [NSString stringWithFormat:@"%.0f%%", v * 100];
        case AUTuneDegrees: return [NSString stringWithFormat:@"%.1f°", v];
        case AUTuneSeconds: return [NSString stringWithFormat:@"%.2g с", v];
        case AUTuneCount: return [NSString stringWithFormat:@"%.0f", v];
        case AUTuneSwitch: return v >= 0.5 ? @"вкл" : @"выкл";
        case AUTunePlain: return [NSString stringWithFormat:@"%.3g", v];
    }
    return @"";
}
