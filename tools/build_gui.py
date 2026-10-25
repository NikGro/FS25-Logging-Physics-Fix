#!/usr/bin/env python3
"""Generates gui/ForestryPhysicsGui.xml and translations/l10n_{de,en}.xml
from the settings list in scripts/FPSettings.lua and the texts below."""
import os
import re
from xml.sax.saxutils import escape

MOD = os.path.join(os.path.dirname(__file__), '..', 'FS25_ForestryPhysicsExperimental')

TEXTS = {
    'fp_guiTitle': ('Forst-Physik (experimentell)', 'Forestry Physics (experimental)'),
    'fp_buttonReset': ('Standardwerte', 'Defaults'),
    'input_FORESTRY_PHYSICS_MENU': ('Forst-Physik: Einstellungen', 'Forestry physics: settings'),
    'fp_lmlLimit': ('Lastmoment %d %% (%s) – Kran begrenzt', 'Load moment %d %% (%s) – crane limited'),
    'fp_lmlSagging': ('Lastmoment %d %% (%s) – Kran sackt ab', 'Load moment %d %% (%s) – crane sagging'),
    'fp_lmlReasonHydraulic': ('Hydraulik', 'hydraulics'),
    'fp_lmlReasonStability': ('Standsicherheit', 'stability'),

    'fp_section_logWeight': ('Frischholz-Gewicht', 'Fresh-cut log weight'),
    'fp_section_grab': ('Greifer', 'Grapples'),
    'fp_section_lml': ('Lastmomentbegrenzung (Kran)', 'Load moment limiter (crane)'),

    'logWeightEnabled': (('Frischholz-Gewicht', 'Neu geschnittene Stämme bekommen das Gewicht von frischem, nassem Holz.'),
                         ('Fresh-cut log weight', 'Newly cut logs get the weight of fresh, wet wood.')),
    'logWeightScale': (('Gewichts-Faktor', '100 % = realistische Frischholz-Dichte. Kleiner, wenn Maschinen zu schnell an ihre Grenzen kommen.'),
                       ('Weight factor', '100 % = realistic green wood density. Lower it if machines reach their limits too quickly.')),
    'logWeightMaxFactor': (('Max. gegenüber Basisspiel', 'Ein Stamm wird höchstens so viel schwerer als im Basisspiel.'),
                           ('Max. vs. base game', 'A log never gets heavier than this times its base game weight.')),

    'grabEnabled': (('Stärkere Greifer', 'Stärkere Klauen und festerer Halt des Stamms im Greifer.'),
                    ('Stronger grapples', 'Stronger claws and a firmer hold of the log in the grapple.')),
    'clawStrength': (('Klauenkraft', 'Haltekraft der Klauen. Gilt für Greifer, sobald sie leer sind.'),
                     ('Claw strength', 'Holding force of the claws. Applied to grapples as soon as they are empty.')),
    'mountStiffness': (('Steifigkeit Halt', 'Wie fest der Stamm am Greifer sitzt (wächst zusätzlich mit dem Gewicht). Gilt ab dem nächsten Greifen.'),
                       ('Grip stiffness', 'How firmly the log sits in the grapple (also grows with the weight). Applied from the next grab.')),
    'maxWobbleDeg': (('Max. Wackeln', 'Wie weit der Stamm im Greifer kippen darf. Gilt ab dem nächsten Greifen.'),
                     ('Max. wobble', 'How far the log may tilt in the grapple. Applied from the next grab.')),
    'lockTranslation': (('Rutschen verhindern', 'Stämme rutschen in Greifern ohne feste Achsen nicht mehr frei hin und her.'),
                        ('Prevent sliding', 'Logs no longer slide freely in grapples without locked axes.')),

    'lmlEnabled': (('Lastmomentbegrenzung', 'Kran bremst und stoppt bei zu viel Last zu weit draußen und sackt bei Überlast ab.'),
                   ('Load moment limiter', 'The crane slows down and stops with too much load too far out, and sags when overloaded.')),
    'lmlHydraulic': (('Hydraulik-Grenze', 'Begrenzt das Hubmoment (Last x Reichweite) wie bei einem echten Kran.'),
                     ('Hydraulic limit', 'Limits the lifting moment (load x reach) like a real crane.')),
    'lmlKnmPerTonne': (('Hubmoment je Tonne Maschine', 'Erlaubtes Hubmoment pro Tonne Maschinengewicht. Echte Forstkräne: etwa 8-11 kNm/t.'),
                       ('Lift moment per machine tonne', 'Allowed lifting moment per tonne of machine weight. Real forestry cranes: about 8-11 kNm/t.')),
    'lmlStability': (('Kippschutz', 'Begrenzt den Kran, bevor die Maschine kippt (aus Gewicht, Schwerpunkt und Radstellung).'),
                     ('Tip protection', 'Limits the crane before the machine tips over (from weight, centre of mass and wheel positions).')),
    'lmlStabilitySafety': (('Kippschutz greift bei', 'Anteil der Kipplast, bei dem der Kran stoppt. Kleiner = sicherer.'),
                           ('Tip protection at', 'Share of the tipping load at which the crane stops. Lower = safer.')),
    'lmlSlowdownStart': (('Abbremsen ab', 'Ab dieser Auslastung wird der Kran beim Ausfahren langsamer.'),
                         ('Slow down from', 'From this utilisation the crane slows down when moving out.')),
    'lmlSagging': (('Absacken bei Überlast', 'Über 100 % senkt sich der Ausleger langsam ab.'),
                   ('Sag when overloaded', 'Above 100 % the boom slowly lowers.')),
    'lmlSagSpeed': (('Absack-Geschwindigkeit', 'Anteil der normalen Kran-Geschwindigkeit beim Absacken.'),
                    ('Sag speed', 'Share of the normal crane speed while sagging.')),
    'lmlShowInfo': (('Hinweis anzeigen', 'Zeigt die Auslastung an, wenn der Kran begrenzt wird.'),
                    ('Show hint', 'Shows the utilisation when the crane is limited.')),
}


def read_settings():
    src = open(os.path.join(MOD, 'scripts', 'FPSettings.lua'), encoding='utf-8').read()
    block = src[src.index('FP.SETTINGS = {'):src.index('FP.SETTINGS_BY_KEY')]
    items = []
    for m in re.finditer(r'\{\s*(section|key)\s*=\s*"(\w+)"(?:,\s*type\s*=\s*"(\w+)")?', block):
        if m.group(1) == 'section':
            items.append(('section', m.group(2), None))
        else:
            items.append(('key', m.group(2), m.group(3)))
    return items


def gui_xml(items):
    out = ['<?xml version="1.0" encoding="utf-8" standalone="no"?>',
           '<!-- generated by tools/build_gui.py -->',
           '<GUI onOpen="onOpen">',
           '  <Bitmap profile="fs25_fullScreenBackground" />',
           '  <GuiElement profile="fs25_menuContainer">',
           '    <GuiElement profile="fs25_menuHeaderPanel">',
           '      <Bitmap profile="fs25_menuHeaderIconBg">',
           '        <Bitmap profile="fs25_menuHeaderIcon" imageSliceId="gui.icon_options_generalSettings2" />',
           '      </Bitmap>',
           '      <Text profile="fs25_menuHeaderTitle" text="$l10n_fp_guiTitle" />',
           '    </GuiElement>',
           '    <ScrollingLayout profile="fs25_settingsLayout" id="boxLayout" topClipperElementName="topClipper" bottomClipperElementName="bottomClipper">']
    for kind, name, typ in items:
        if kind == 'section':
            out.append(f'      <Text profile="fs25_settingsSectionHeader" name="sectionHeader" text="$l10n_fp_section_{name}" />')
            continue
        elem = 'BinaryOption' if typ == 'bool' else 'MultiTextOption'
        prof = 'fs25_settingsBinaryOption' if typ == 'bool' else 'fs25_settingsMultiTextOption'
        out += [f'      <Bitmap profile="fs25_multiTextOptionContainer">',
                f'        <{elem} profile="{prof}" id="opt_{name}">',
                f'          <Text profile="fs25_multiTextOptionTooltip" name="ignore" text="$l10n_fp_{name}TT" />',
                f'        </{elem}>',
                f'        <Text profile="fs25_settingsMultiTextOptionTitle" text="$l10n_fp_{name}Title" />',
                f'      </Bitmap>']
    out += ['    </ScrollingLayout>',
            '    <Bitmap profile="fs25_settingsTooltipSeparator" />',
            '    <Bitmap profile="fs25_startClipper" name="topClipper" />',
            '    <Bitmap profile="fs25_stopClipper" name="bottomClipper" />',
            '  </GuiElement>',
            '  <ThreePartBitmap profile="fs25_sliderDockedBg">',
            '    <ThreePartBitmap profile="fs25_sliderDockedBox">',
            '      <Slider profile="fs25_sliderDocked" dataElementId="boxLayout" />',
            '    </ThreePartBitmap>',
            '  </ThreePartBitmap>',
            '  <BoxLayout profile="fs25_buttonBox">',
            '    <Button profile="buttonBack" text="$l10n_button_back" onClick="onClickBack">',
            '      <Bitmap profile="fs25_buttonBoxSeparator" name="separator" />',
            '    </Button>',
            '    <Button profile="buttonExtra1" text="$l10n_fp_buttonReset" onClick="onClickReset">',
            '      <Bitmap profile="fs25_buttonBoxSeparator" name="separator" />',
            '    </Button>',
            '    <Button profile="buttonOK" text="$l10n_button_ok" onClick="onClickOk">',
            '      <Bitmap profile="fs25_buttonBoxSeparator" name="separator" />',
            '    </Button>',
            '  </BoxLayout>',
            '</GUI>', '']
    return '\n'.join(out)


def l10n_xml(items, lang):
    idx = 0 if lang == 'de' else 1
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<!-- generated by tools/build_gui.py -->', '<l10n>', '    <texts>']
    for key, val in TEXTS.items():
        if isinstance(val[0], tuple):
            title, tip = val[idx]
            out.append(f'        <text name="fp_{key}Title" text="{escape(title, {chr(34): "&quot;"})}" />')
            out.append(f'        <text name="fp_{key}TT" text="{escape(tip, {chr(34): "&quot;"})}" />')
        else:
            out.append(f'        <text name="{key}" text="{escape(val[idx], {chr(34): "&quot;"})}" />')
    out += ['    </texts>', '</l10n>', '']
    return '\n'.join(out)


def main():
    items = read_settings()
    keys = [n for k, n, _ in items if k == 'key']
    missing = [k for k in keys if k not in TEXTS]
    assert not missing, f'missing texts for {missing}'
    os.makedirs(os.path.join(MOD, 'gui'), exist_ok=True)
    os.makedirs(os.path.join(MOD, 'translations'), exist_ok=True)
    open(os.path.join(MOD, 'gui', 'ForestryPhysicsGui.xml'), 'w', encoding='utf-8', newline='\n').write(gui_xml(items))
    open(os.path.join(MOD, 'gui', 'guiProfiles.xml'), 'w', encoding='utf-8', newline='\n').write(
        '<?xml version="1.0" encoding="utf-8" standalone="no"?>\n<GUIProfiles>\n</GUIProfiles>\n')
    for lang in ('de', 'en'):
        open(os.path.join(MOD, 'translations', f'l10n_{lang}.xml'), 'w', encoding='utf-8', newline='\n').write(l10n_xml(items, lang))
    print(f'{len(keys)} settings, {sum(1 for k, _, _ in items if k == "section")} sections')


if __name__ == '__main__':
    main()
