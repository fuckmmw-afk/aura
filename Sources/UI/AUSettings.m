#import "AUSettings.h"
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Core/AUTaurus.h"
#import "Features/AUPipeline.h"
#import "UI/AULockScreen.h"

#define ADD(array, row) do { id _r = (row); if (_r) [(array) addObject:_r]; } while (0)

static NSString *const kRestart = @"Переключатели работают сразу. Кнопки и ползунок в цвет обложки красит «Follow the cover» Taurus: его Aura включает сама, он вступает после перезапуска.";

static SGModRow *modelRow(NSString *modelID, NSString *feature) {
    AUModelManager *models = AUModelManager.shared;
    NSString *subtitle = [NSString stringWithFormat:@"%@ · %@", feature, [models licenseOf:modelID]];
    SGModRow *row = AURowStatAction([models titleOf:modelID], subtitle, ^NSString *{ return [models statusTextOf:modelID]; }, ^{
        [models ensure:modelID];
    });
    row.refreshOn = AUModelsDidChangeNotification;
    return row;
}

UIViewController *AUSettingsPage(void) {
    if (!AUTaurusRowsAvailable()) return nil;
    NSMutableArray *sections = [NSMutableArray array];
    BOOL redesigned = AUTaurusRedesigned();

    NSMutableArray *cover = [NSMutableArray array];
    if (!redesigned) {
        SGModRow *warning = AURowAction(@"Нужен Redesigned UI", @"Aura работает только в редизайне Taurus: Appearance → Redesigned UI", ^{});
        warning.color = UIColor.systemOrangeColor;
        warning.symbol = @"exclamationmark.triangle.fill";
        ADD(cover, warning);
    }
    SGModRow *theme = AURowSwitch(@"Тема под трек", @"Стекло, кнопки и ползунок перетекают в цвета обложки", AUKeyTheme);
    theme.changed = ^(BOOL on) {
        if (on && !AUTaurusFollowsCover()) AUTaurusSetSwitch(AUTaurusKeyFollowsCover, YES);
        AUSettingsChanged();
    };
    ADD(cover, AURowSymbol(theme, @"paintpalette.fill"));
    SGModRow *scope = AURowChoice(@"Где красить стекло", nil, AUKeyThemeScope, @[@"Везде", @"Только в плеере"], 0);
    scope.chosen = ^(NSInteger index) { AUSettingsChanged(); };
    scope.waitsOn = AUKeyTheme;
    ADD(cover, scope);
    SGModRow *tint = AURowSlider(@"Сила тинта", nil, 0.1, 0.6, 0.02, ^double { return AUNumber(AUKeyThemeStrength, 0.32); },
                                 ^(double value) { AUSetNumber(AUKeyThemeStrength, value); },
                                 ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value * 100]; });
    tint.waitsOn = AUKeyTheme;
    ADD(cover, tint);
    SGModRow *depth = AURowSwitch(@"Живые обложки", @"Карта глубины и гироскоп: обложка как 3D-открытка", AUKeyDepth);
    depth.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(depth, @"cube.transparent"));
    SGModRow *strength = AURowSlider(@"Сила параллакса", nil, 0.3, 3.0, 0.1, ^double { return AUNumber(AUKeyDepthStrength, 1.0); },
                                     ^(double value) { AUSetNumber(AUKeyDepthStrength, value); },
                                     ^NSString *(double value) { return [NSString stringWithFormat:@"×%.1f", value]; });
    ADD(cover, strength);
    SGModRow *cutout = AURowSwitch(@"Артист из обложки", @"Человек выходит из кадра поверх стекла, фон размывается", AUKeyCutout);
    cutout.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(cutout, @"person.crop.rectangle.stack"));
    SGModRow *objects = AURowOption(@"Не только люди", @"Вырезать и животных, и предметы", AUKeyCutoutObjects);
    objects.changed = ^(BOOL on) { AUSettingsChanged(); };
    objects.waitsOn = AUKeyCutout;
    ADD(cover, objects);
    SGModRow *upscale = AURowSwitch(@"Апскейл обложек", @"Обложки меньше 600 px дотягиваются нейросетью", AUKeyUpscale);
    upscale.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(upscale, @"arrow.up.left.and.arrow.down.right"));
    ADD(sections, AUSection(@"Обложка и тема", cover, kRestart));

    NSMutableArray *lock = [NSMutableArray array];
    SGModRow *lockRow = AURowChoice(@"Обложка на экране блокировки", nil, AUKeyLockScreen, @[@"3D-облёт", @"Растянуть", @"Выкл"], 0);
    lockRow.chosen = ^(NSInteger index) { AUSettingsChanged(); };
    ADD(lock, AURowSymbol(lockRow, @"lock.iphone"));
    ADD(sections, AUSection(@"Экран блокировки", lock, @"iOS 26+. Обложка на весь экран блокировки. «3D-облёт» — зацикленное видео: камера медленно ходит над картой глубины, артист впереди (гироскопа на локскрине нет). Заменяет стиль экрана блокировки Taurus."));

    NSMutableArray *models = [NSMutableArray array];
    ADD(models, modelRow(AUModelDepth, @"глубина"));
    ADD(models, modelRow(AUModelUpscale, @"апскейл"));
    SGModRow *vision = AURowStat(@"Vision · маска человека", ^NSString *{ return @"системная · 0 МБ"; });
    ADD(models, vision);
    SGModRow *kmeans = AURowStat(@"Палитра · k-means (vDSP)", ^NSString *{ return @"без нейросети · 0 МБ"; });
    ADD(models, kmeans);
    ADD(sections, AUSection(@"Модели", models, @"Модели качаются с сервера при первой нужде (тап по строке — скачать сейчас), один раз компилируются на телефоне и лежат в Application Support. В памяти — только пока нужны."));

    NSMutableArray *cache = [NSMutableArray array];
    ADD(cache, AURowStat(@"Кеш обложек", ^NSString *{ return AUBytes([AUPipeline.shared cacheBytes]); }));
    ADD(cache, AURowAction(@"Очистить кеш", @"Глубина, маски, палитры и апскейлы посчитаются заново", ^{ [AUPipeline.shared clearCache]; }));
    SGModRow *drop = AURowAction(@"Удалить модели", @"Скачаются снова, когда понадобятся", ^{ [AUModelManager.shared deleteAll]; });
    drop.color = UIColor.systemRedColor;
    ADD(cache, drop);
    ADD(sections, AUSection(@"Кеш", cache, nil));

    NSMutableArray *stats = [NSMutableArray array];
    ADD(stats, AURowStat(@"Обложка → эффекты", ^NSString *{ return AUStatText(@"shown"); }));
    ADD(stats, AURowStat(@"Палитра", ^NSString *{ return AUStatText(@"palette"); }));
    ADD(stats, AURowStat(@"Глубина", ^NSString *{ return AUStatText(@"depth"); }));
    ADD(stats, AURowStat(@"Вырезка", ^NSString *{ return AUStatText(@"cutout"); }));
    ADD(stats, AURowStat(@"Апскейл", ^NSString *{ return AUStatText(@"upscale"); }));
    ADD(stats, AURowStat(@"Загрузка модели глубины", ^NSString *{ return AUStatText(@"load." AUModelDepth); }));
    ADD(stats, AURowStat(@"Память Spotify", ^NSString *{ return [NSString stringWithFormat:@"%@ (пик %@)", AUBytes(AUFootprint()), AUBytes(AUPeakFootprint())]; }));
    ADD(stats, AURowStat(@"Температура", ^NSString *{ return AUThermalName(); }));
    SGModRow *thermal = AURowOption(@"Пауза при перегреве", @"При «горячем» телефоне оставлять только палитру", AUKeyThermalPause);
    thermal.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:AUThrottleDidChangeNotification object:nil];
        AUSettingsChanged();
    };
    ADD(stats, thermal);
    ADD(stats, AURowAction(@"Поделиться логом", @"Documents/Aura/aura.log, в нём строка телеметрии раз в минуту", ^{ AUShareFile(AULogURL()); }));
    ADD(sections, AUSection(@"Диагностика", stats, nil));

    NSString *footer = [NSString stringWithFormat:@"Aura %s — отдельный аддон к Taurus, ничего в Taurus не меняет.\nTaurus © Vojtěch Škopek (spoti.pw), PolyForm Strict 1.0.0.\nDepth Anything V2 — Apache-2.0, Real-ESRGAN — BSD-3-Clause.", AURA_VERSION];
    return [[NSClassFromString(@"SGModPage") alloc] initWithTitle:@"Aura" intro:nil sections:sections footer:footer];
}

NSArray *AUSettingsWithAuraRow(NSArray *sections) {
    SGModRow *row = AURowPage(@"Aura · ИИ-эффекты", ^UIViewController *{ return AUSettingsPage(); });
    row = AURowSymbol(row, @"sparkles");
    if (!row) return sections;
    row.value = ^NSString *{ return AUTaurusRedesigned() ? @"" : @"нужен редизайн"; };
    SGModSection *section = AUSection(nil, @[row], nil);
    if (!section) return sections;
    NSMutableArray *all = [sections mutableCopy] ?: [NSMutableArray array];
    [all insertObject:section atIndex:MIN((NSUInteger)1, all.count)];
    return all;
}
