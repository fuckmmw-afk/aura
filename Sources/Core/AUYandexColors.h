#import <UIKit/UIKit.h>

#define AUKeyWhiteAccent @"aura.ym.white"   // on until switched off; read at launch

// Called from Aura's constructor in Yandex Music, before the app's own code runs.
void AUYandexColorsInstall(void);
