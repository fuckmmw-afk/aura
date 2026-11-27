#import "AUSettings.h"
#import "Core/AUCore.h"
#import "Core/AUModelManager.h"
#import "Core/AUTune.h"
#import "Core/AUTaurus.h"
#import "Core/AUYandex.h"
#import "Features/AUPipeline.h"
#import "UI/AULockScreen.h"
#import "UI/AUVideoCover.h"
#import "UI/AULyrics.h"
#import "UI/AUYandexFill.h"
#import "Core/AUYandexColors.h"

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

// A change shows once the hand has stopped: at once for the look, after a pause for what is made again (scenes, clips).
static void tuneChanged(AUTuneEffect effect) {
    static NSUInteger generation;
    NSUInteger mine = ++generation;
    double delay = effect == AUTuneLive ? 0.3 : 1.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == generation) AUSettingsChanged();
    });
}

static UIViewController *tunePage(void) {
    NSMutableArray *sections = [NSMutableArray array];
    for (AUTuneSection *tuneSection in AUTuneSections()) {
        NSMutableArray *rows = [NSMutableArray array];
        for (AUTuneItem *item in tuneSection.items) {
            NSString *name = item.name;
            AUTuneEffect effect = item.effect;
            if (item.format == AUTuneSwitch) {
                NSString *key = [@"aura.t." stringByAppendingString:name];
                SGModRow *row = item.fallback >= 0.5 ? AURowSwitch(item.title, item.subtitle, key) : AURowOption(item.title, item.subtitle, key);
                row.changed = ^(BOOL on) { tuneChanged(effect); };
                ADD(rows, row);
                continue;
            }
            NSString *subtitle = [NSString stringWithFormat:@"%@%@по умолчанию %@", item.subtitle ?: @"", item.subtitle ? @" · " : @"",
                                  AUTuneText(item, item.fallback)];
            SGModRow *row = AURowSlider(item.title, subtitle, item.minimum, item.maximum, item.step,
                                        ^double { return AUTune(name); },
                                        ^(double value) {
                                            AUTuneSet(name, value);
                                            tuneChanged(effect);
                                        },
                                        ^NSString *(double value) { return AUTuneText(item, value); });
            ADD(rows, row);
        }
        ADD(sections, AUSection(tuneSection.title, rows, tuneSection.footer));
    }
    NSMutableArray *reset = [NSMutableArray array];
    SGModRow *resetRow = AURowAction(@"Сбросить всё", @"Все числа этой страницы — к значениям по умолчанию", ^{
        AUTuneResetAll();
        tuneChanged(AUTuneScene);
    });
    resetRow.color = UIColor.systemRedColor;
    ADD(reset, resetRow);
    ADD(sections, AUSection(nil, reset, @"Ползунок «Сила параллакса» на главной странице умножает размах поворота в плеере и на экране блокировки."));
    return AUMakePage(@"Тонкая настройка", nil, sections, nil);
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
    BOOL yandex = AUHostYandex();
    SGModRow *theme = AURowSwitch(@"Тема под трек", yandex ? @"Стекло перетекает в цвета обложки" : @"Стекло, кнопки и ползунок перетекают в цвета обложки", AUKeyTheme);
    theme.changed = ^(BOOL on) {
        if (on && !yandex && !AUTaurusFollowsCover()) AUTaurusSetSwitch(AUTaurusKeyFollowsCover, YES);
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
    SGModRow *depth = AURowSwitch(@"Живые обложки", @"3D-сцена: объекты обложки целыми слоями над дорисованным фоном, движутся от гироскопа", AUKeyDepth);
    depth.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(depth, @"cube.transparent"));
    SGModRow *mode = AURowChoice(@"Метод параллакса", nil, AUKeyMotionMode, @[@"3D-сцена", @"Упрощённый (одним слоем)"], 0);
    mode.chosen = ^(NSInteger index) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(mode, @"square.3.layers.3d"));
    SGModRow *strength = AURowSlider(@"Сила параллакса", nil, 0.3, 3.0, 0.1, ^double { return AUNumber(AUKeyDepthStrength, 1.0); },
                                     ^(double value) { AUSetNumber(AUKeyDepthStrength, value); },
                                     ^NSString *(double value) { return [NSString stringWithFormat:@"×%.1f", value]; });
    ADD(cover, strength);
    SGModRow *tune = AURowPage(@"Тонкая настройка", ^UIViewController *{ return tunePage(); });
    ADD(cover, AURowSymbol(tune, @"slider.horizontal.3"));
    SGModRow *cutout = AURowOption(@"Артист из обложки", @"Объекты чуть крупнее и выходят за рамку обложки", AUKeyPopOut);
    cutout.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(cutout, @"person.crop.rectangle.stack"));
    SGModRow *people = AURowOption(@"Только люди", @"Отдельными слоями только люди, остальное остаётся фоном", AUKeyScenePeopleOnly);
    people.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, people);
    SGModRow *upscale = AURowSwitch(@"Апскейл обложек", @"Обложки меньше 600 px дотягиваются нейросетью", AUKeyUpscale);
    upscale.changed = ^(BOOL on) { AUSettingsChanged(); };
    ADD(cover, AURowSymbol(upscale, @"arrow.up.left.and.arrow.down.right"));
    ADD(sections, AUSection(@"Обложка и тема", cover, yandex ? @"Переключатели работают сразу. Эффекты — на обложке в полноэкранном плеере." : kRestart));

    if (yandex) {
        NSMutableArray *ui = [NSMutableArray array];
        SGModRow *white = AURowSwitch(@"Белый вместо жёлтого", @"Жёлтые кнопки и акценты Яндекса — белые. Вступает после перезапуска приложения", AUKeyWhiteAccent);
        ADD(ui, AURowSymbol(white, @"circle.lefthalf.filled"));
        SGModRow *fill = AURowSwitch(@"Fill", @"Как в Spotify: обложка во всю ширину сверху, ниже — продолжение, дорисованное нейросетью, с 3D-сценой; обложка в карусели скрыта", AUKeyYandexFill);
        fill.changed = ^(BOOL on) { AUSettingsChanged(); };
        ADD(ui, AURowSymbol(fill, @"rectangle.inset.topleft.filled"));
        ADD(ui, AURowSymbol(AURowPage(@"Текст песни", ^UIViewController *{ return AULyricsSettingsPage(); }), @"quote.bubble.fill"));
        ADD(sections, AUSection(@"Интерфейс Яндекса", ui, nil));
    }

    NSMutableArray *lock = [NSMutableArray array];
    SGModRow *lockRow = AURowChoice(@"Обложка на экране блокировки", nil, AUKeyLockScreen, @[@"3D-облёт", @"Растянуть", @"Выкл"], 0);
    lockRow.chosen = ^(NSInteger index) { AUSettingsChanged(); };
    ADD(lock, AURowSymbol(lockRow, @"lock.iphone"));
    if (yandex) {
        SGModRow *video = AURowSwitch(@"Видео-обложки", @"Если у трека в Яндексе есть видео, на экране блокировки — оно, а не 3D-облёт", AUKeyLockVideo);
        video.changed = ^(BOOL on) { AUSettingsChanged(); };
        ADD(lock, AURowSymbol(video, @"play.rectangle.fill"));
    }
    ADD(sections, AUSection(@"Экран блокировки", lock, !yandex ? @"iOS 26+. Обложка на весь экран блокировки. «3D-облёт» — зацикленное видео: камера медленно ходит над картой глубины, артист впереди (гироскопа на локскрине нет)."
                                                                       " Заменяет стиль экрана блокировки Taurus." : @"iOS 26+. Обложка на весь экран блокировки. «3D-облёт» — зацикленное видео: камера медленно ходит над картой глубины, артист впереди (гироскопа на локскрине нет)."));

    NSMutableArray *models = [NSMutableArray array];
    ADD(models, modelRow(AUModelDepth, @"глубина"));
    ADD(models, modelRow(AUModelUpscale, @"апскейл"));
    ADD(models, modelRow(AUModelInpaint, @"дорисовка фона"));
    ADD(models, modelRow(AUModelSamEncoder, @"все объекты"));
    ADD(models, modelRow(AUModelSamPrompt, @"все объекты"));
    ADD(models, modelRow(AUModelSamDecoder, @"все объекты"));
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
    ADD(stats, AURowStat(@"Сцена (объекты + дорисовка)", ^NSString *{ return AUStatText(@"scene"); }));
    ADD(stats, AURowStat(@"Из них дорисовка LaMa", ^NSString *{ return AUStatText(@"inpaint"); }));
    ADD(stats, AURowStat(@"Апскейл", ^NSString *{ return AUStatText(@"upscale"); }));
    ADD(stats, AURowStat(@"Загрузка модели глубины", ^NSString *{ return AUStatText(@"load." AUModelDepth); }));
    ADD(stats, AURowStat([@"Память " stringByAppendingString:AUHostName()], ^NSString *{ return [NSString stringWithFormat:@"%@ (пик %@)", AUBytes(AUFootprint()), AUBytes(AUPeakFootprint())]; }));
    ADD(stats, AURowStat(@"Температура", ^NSString *{ return AUThermalName(); }));
    SGModRow *thermal = AURowOption(@"Пауза при перегреве", @"При «горячем» телефоне оставлять только палитру", AUKeyThermalPause);
    thermal.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:AUThrottleDidChangeNotification object:nil];
        AUSettingsChanged();
    };
    ADD(stats, thermal);
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL *sideloadLog = [documents URLByAppendingPathComponent:@"SideloadFix.log"];
    if ([NSFileManager.defaultManager fileExistsAtPath:sideloadLog.path]) {
        ADD(stats, AURowAction(@"Поделиться логом Sideload Fix", @"Documents/SideloadFix.log: группы, связка ключей", ^{ AUShareFile(sideloadLog); }));
    }
    ADD(stats, AURowAction(@"Поделиться логом", @"Documents/Aura/aura.log, в нём строка телеметрии раз в минуту", ^{ AUShareFile(AULogURL()); }));
    ADD(sections, AUSection(@"Диагностика", stats, nil));

    NSString *footer = yandex ? [NSString stringWithFormat:@"Aura %s для Яндекс Музыки. Открыть эту страницу из плеера — удержать обложку двумя пальцами.\nDepth Anything V2 — Apache-2.0, Real-ESRGAN — BSD-3-Clause, Big-LaMa — Apache-2.0, SAM 2.1 — Apache-2.0.", AURA_VERSION] : [NSString stringWithFormat:@"Aura %s — отдельный аддон к Taurus, ничего в Taurus не меняет.\nTaurus © Vojtěch Škopek (spoti.pw), PolyForm Strict 1.0.0.\nDepth Anything V2 — Apache-2.0, Real-ESRGAN — BSD-3-Clause, Big-LaMa — Apache-2.0, SAM 2.1 — Apache-2.0.", AURA_VERSION];
    return AUMakePage(@"Aura", nil, sections, footer);
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
