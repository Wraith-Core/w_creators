# w_creators — Wraith Core RedM

منظومة اختيار الشخصيات وإنشائها، مواقع الظهور، الملابس والخزائن والحلاقة. البيانات والبرومبتات والمعاملات تمر عبر `w_lib`، واللغة تتبع اختيار المكتبة `ar` / `en`.

## الإصدار 1.1.0 — 2026-11-08

- توحيد التصميم (الموجة الثانية): صفحة إنشاء الشخصية، وبطاقة اختيار الشخصية، وصفحات متجر الملابس والحلاق وعيادة التجميل والخزانة صارت على «طقم اللوحات» نفسه الذي تستخدمه لوحة القطار ولوحة الصناعة (`web/src/kit.css`).
- الصفحة لم تعد تعتمد على ثيم `w_lib`؛ الخطوط (EB Garamond، لالي زار، RDR Lino، RDR Catalogue) والقوام (الحافة الممزقة، الحبيبات، الشريط) صارت ملفات داخل السكربت نفسه. حُذفت خطوط قديمة لم تكن مستخدمة (Hapna، Noto، Tajawal).
- الشعار في أعلى اللوحة صار من ملفات اللغة: «ريد ريفر · استوديو الشخصيات» بالعربي، والاسم اللاتيني بالإنجليزي.
- مؤشر الماوس شريط ورقي أبيض، والاختيار (القسم المفتوح، الجنس، «مرتداة»، إخفاء الملابس) بالأحمر. البطاقة التي عليها المؤشر تفتح قليلًا وعليها الشريط الأحمر الصغير.
- نافذة التأكيد هي ورقة الطقم: خيارات نصية، والخطر عليه خط أحمر تحته.
- بطاقة اختيار الشخصية صارت في جهة البداية: يمين الشاشة بالعربي ويسارها بالإنجليزي، والتظليل من نفس الجهة. أرقام المال فيها بخط RDR Catalogue.
- توقيع الاسم في بطاقة المراجعة بخط العناوين (لالي زار بالعربي).
- مقبض شريط التمرير يبقى أبيض (الأحمر للحالات الحرجة فقط).
- الأقسام التسعة تبقى في شبكة 3×3 لأنها لا تتسع في سطر واحد بلوحة ضيقة تترك الشخصية ظاهرة؛ شكلها الآن تبويبات الطقم.
- نفس الرسائل ونفس الاستدعاءات؛ تغيير Lua الوحيد: نص الشعار `brand` في `client/editor/editor.lua`.

**للتجربة في اللعبة:** إنشاء شخصية جديدة (كل الأقسام، الهوية، المراجعة، زر الإنهاء)، بطاقة اختيار الشخصية عند الدخول (بالعربي يمين الشاشة)، متجر الملابس مع نافذة الشراء، الحلاق، الخزانة، ولوحة `/servicesadmin` (لم تتغير إلا الخطوط اللاتينية). جرّب 1280×720 وشاشة عريضة إن وجدت.

## الإصدار 1.0.17 — 2026-11-06

- طلب المالك: كل لاعب يبدأ بشخصية واحدة، والـ VIP مثله. من يشتري **«خانة شخصية إضافية»** من المتجر يصير عنده شخصية ثانية (كل خانة يشتريها تضيف شخصية).
- من لم يشترِ خانة لا يقدر يصنع شخصية ثانية.

## الإصدار 1.0.16 — 2026-11-06

- طلب المالك: **شخصية واحدة لكل لاعب**، والـ VIP مثله. لم يعد الـ VIP ولا المتجر يعطيان خانة شخصية إضافية (`Config.Characters.defaultSlots = 1`، و`slotPermissions` فارغة).
- من عنده أكثر من شخصية من قبل تبقى شخصياته، لكنه لا يستطيع إنشاء شخصية جديدة.

## المظهر

- تجهيز مشهد واحد للاختيار والإنشاء: تأكيد العزل من السيرفر، تثبيت شخصية المعاينة، ثم انتظار جاهزية المظهر قبل كشف المشهد. عند تعذر التحميل يظهر زر إعادة المحاولة من المكتبة.
- الكاميرا تتجه إلى الشخصية الفعلية وتثبت زاويتها أثناء تدوير الشخصية. `Config.Scene.editingPed` يحدد مكان التعديل، و`Config.Scene.selectionPed` يحدد مكان المعاينة (`config/main.lua`)؛ ضبط اللقطات في `client/camera/camera.lua` (`WCCamera`).
- مشهد الإنشاء على خشبة مسرح سانت دينيس: الرجل والمرأة متجاوران والكاميرا على الاثنين. ← يفتح المحرر على الرجل مباشرة و→ على المرأة، ويُعدَّل كل منهما في مكانه (`editingPed = nil`) والآخر مخفي. زر «تغيير الجنس» في المحرر يعيد إلى الاثنين ويحفظ مسودة كل جنس والاسم المكتوب، والجنس يُرسل للسيرفر عند الحفظ فقط. الإضاءة الملوّنة وعدد المارة وأماكن الشخصيات والكاميرا كلها في `Config.Scene`.
- الضغط على الوجه أو العينين أو الجسم أو الساقين أو الحذاء يقرّب الجزء مباشرةً عبر `w.raycast.pedPartFromScreen`. السحب يدوّر الشخصية، وعجلة الماوس تقرّب وتبعد، والزر اليمين يعيد العرض الكامل. تلميح الكاميرا في أسفل الوسط، ويعمل التحكم نفسه في الإنشاء والخياط والخزانة والحلاق.
- مسار تطبيق واحد للإنشاء والمعاينة والظهور ومزامنة اللاعبين.
- **الصوت (2026-10-19):** نموذج شخصية اللاعب في اللعبة بلا صوت كلام، فكانت اللعبة تتكلم بصوت جون مارستن للجميع. الآن لكل شخصية **صوت كلام** من أصوات اللعبة (امرأة / رجل) بثلاث نبرات: عادي، خشن، راقٍ، ومعه أصوات الجسد (الألم والتنفس والجهد). يُختار في الإنشاء وفي **عملية التجميل** (قسم «الجسد» ← «البنية»)، وزر «استمع إلى الصوت» يُسمع تحية بالصوت المختار. يُحفظ مع الشخصية (`voice` من 1 إلى 3، ونوعه يتبع الجنس) ويُطبَّق عند كل ظهور وعلى شخصيات اللاعبين الآخرين. الشخصيات القديمة تأخذ النبرة الأولى لجنسها. الحلاق والخزانة والمتجر لا يغيّرون الصوت.
- **التحية والاستفزاز بصوت الشخصية:** تحية واستفزاز اللعبة نفسها تستخدم جمل جون فقط، فتسكت مع صوت آخر. عند التركيز على شخص تظهر أزرارنا «تحية» و«استفزاز» على نفس أزرار اللعبة، والسيرفر يختار الجملة والصوت من شخصيتك المحفوظة ويُسمعها للاعبين حولك (30 م)، والشخص يرد بصوته (`config/voice.lua`، `client/voice/speak.lua`، `server/voice/speak.lua`).
- تخزين معرفات القطع الثابتة؛ قراءة صيغة `{model, variation}` القديمة وتحويلها عند الحفظ دون حذف الشخصيات.
- الرأس والعينان والأسنان والجسم أجزاء إلزامية. الزي الأساسي يسبق تطبيق الوجه، ولا توجد ملابس عشوائية في الاسترجاع.
- 63 تحكمًا فريدًا للوجه والجسم في `shared/morphology.lua` (أسماء `w_lib`). أقسام فرعية للعينين والأنف والفم والفك والخدين والأذنين.
- التعديل العشوائي يقتصر على أجزاء صالحة وملامح معتدلة. لا يضيف الأقنعة أو المكياج.
- حفظ الطول والوزن والملامح والطبقات معًا. التراجع واستعادة الأصل متاحان قبل التأكيد.

## الخياط والخزانة والحلاق

مفتاح التفاعل عند المتاجر والخزائن والحلاق والعيادة صار J بدل E (لأن E يمسك اللاعب القريب).

نفس محرر React والكاميرا في كل الأوضاع. تظهر برومبتات `w_lib` عند الأماكن المحددة من لوحة `/servicesadmin` (أول نسخة منها جاءت من `config/locations.lua`)، وتستخدم البلبات جسر المكتبة للخريطة.

**لوحة أماكن الخدمات (2026-10-19، الأمر `/servicesadmin`، الصلاحية `w_creators.admin`):** الإداري يدير من داخل اللعبة أماكن متاجر الملابس والحلاقين وعيادات التجميل والخزائن، بنفس تصميم لوحاتنا. يضيف مكانًا حيث يقف، ويغيّر الاسم والمدينة والتفعيل وعلامة الخريطة ومسافة الزر وموديل البوت، ويضع بمحرر المكان: نقطة الزر والبوت، ومكان التعديل، وكتاب الملابس، وكرسي الحلاقة (كرسي جديد، أو كرسي موجود في الماب ينظر إليه ويضغط J). الأماكن تُحفظ في جدول `w_creators_locations` (نُسخت إليه أماكن `config/locations.lua` مرة واحدة، والمكان المحذوف لا يرجع)، وتصل لكل اللاعبين فورًا، ولا تتغيّر تحت لاعب في منتصف زيارة. عند الحلاق الذي له كرسي يجلس اللاعب على الكرسي بحركة اللعبة نفسها (`PROP_PLAYER_BARBER_SEAT`، والارتفاع في `Config.Barber.chair`). أماكن العيادات تُرسل إلى w_medic فيتغيّر زر العملية في المستشفى معها، والبوت الذي يضعه الإداري للعيادة يظهر عندها.

الواجهة تتبع ثيم الهود والحقيبة والكرافتنج: أبيض وأسود، إطارات `crafting_highlight` وتكسشرات الأزرار والفواصل الأصلية، وصور الملابس ومنتجات الشعر من الحقيبة. الأصول محلية داخل `web/public/tex/ui` وتُضمّن في البناء؛ لا يحتاج المحرر إلى تشغيل الحقيبة أو الكرافتنج لعرضها. الحفظ والكاميرا وبطاقة اختيار الشخصية تستخدم نفس التصميم، واللغة من `w_lib`.

المحرر قائمة جانبية ضيقة بعرض يقارب 23% من الشاشة، بعمود واحد. اختيار القسم يفتح قائمته في نفس المكان، واختيار أحد عناصره يعرض تحكمه فقط. الملامح مقسّمة إلى قوائم للرأس والعينين والأنف والفم والفك والخدين والأذنين. الأسهم للأعلى والأسفل تنقل بين الصفوف، وEnter يفتح العنصر، وEscape يرجع مستوى واحدًا؛ من القائمة الرئيسية يفتح تأكيد الإلغاء. يحتفظ التنقل بالاسم والتعديلات، ويحدد القسم موضع الكاميرا تلقائيًا.

الخياط يبيع الملابس فقط، والخزانة تعرض القطع المملوكة والزي الذي دخل به اللاعب، والحلاق يعدل شعر الرجال والنساء ولحية الرجال. لا يغيّر شراء الملابس ملامح الوجه. الإلغاء يسترجع المظهر السابق ويعيد اللاعب من غرفة القياس. التأكيد يحفظ القطع والملكية معًا، والخصم يُعاد عند فشل معاملة قاعدة البيانات.

`exports.w_creators:OpenWardrobe()` متاح للموارد الأخرى. الأسعار والمواقع تضبط من ملفات `config/*.lua` (المواقع في `config/locations.lua`)، ولا تُقبل أسعار من الواجهة.

## الحلاق، ونمو الشعر واللحية (متوقف)

**النمو التلقائي متوقف منذ 1.0.5 (طلب المالك 2026-11-01):** `Config.Grooming.enabled = false`، فلا يطول الشعر ولا اللحية
وحدهما، والحلاق لاختيار القصة فقط. ما يلي يصف النمو كما يعمل لو أُعيد تشغيله (`enabled = true`).

إعدادات `config/barber.lua` (`Config.Grooming` و`Config.Barber`):

- `Config.Grooming.enabled`: تشغيل النمو (الافتراضي الآن `false`).
- `minutesPerStage.hair = 120` و`beard = 60`: دقائق اللعب الفعلية لكل مرحلة.
- `stages`: أسماء موديلات MP لمراحل نمو مستقلة لشعر الرجال والنساء وللحية الرجال. يحتفظ الانتقال بدرجة اللون.
- `Config.Barber.services.{hair,facialHair,details}.price`: سعر كل خدمة تتغير في الزيارة (الافتراضي 10 للشعر و10 للحية و5 للتفاصيل)، و`Config.Barber.prices.visitCap = 10`: أقصى ما تكلفه زيارة واحدة (`nil` = بلا حد).
- مواقع الحلاقة هي مدخلات `type = 'barber'` في `config/locations.lua`.

العداد من السيرفر (`server/barber/grooming.lua`)، ويتوقف أثناء اختيار الشخصية والقياس والحلاقة وخارج العالم الأساسي. لا يحتسب وقت إغلاق اللعبة. يتراكم التقدم في الذاكرة ويُحفظ داخل `grooming` في مظهر v3 عند تغيّر المرحلة، وكل `saveIntervalSeconds`، وعند الخروج أو تبديل الشخصية؛ قد تُفقد الفترة غير المحفوظة عند إعادة تشغيل المورد. الحلاقة تعيد عداد الجزء المعدّل فقط، والحلاقة الكاملة تبدأ من المرحلة صفر.

النمو يتم بتبديل موديلات MP على مراحل؛ ليس تمديدًا مستمرًا لشبكة الشعر. يمكن ضبط ترتيب الموديلات لكل جنس في `stages`، ويحتاج ترتيب الأطوال والمعاينة على مختلف الرؤوس إلى تحقق بصري داخل RedM. لا تتغير ملامح الوجه أو الملابس مع نبضة النمو.

## عدد الشخصيات وعضوية VIP (2026-10-21)

- كل لاعب له 3 شخصيات (`Config.Characters.defaultSlots`). عضو VIP بأي رتبة (المورد **w_vip**، اشتراك شهري من متجر السيرفر)
  له **4 شخصيات** (شخصية واحدة زيادة فقط، طلب المالك): `slotPermissions = { ['w_creators.slots.vip'] = 4 }` في `config/main.lua`.
- الصلاحية `w_creators.slots.vip` يعطيها w_vip لمجموعة `vip.bronze` وكل رتبة أعلى ترثها. إذا لم يعمل w_vip فلا أحد يملكها والعدد 3 كما كان.
- إذا انتهت العضوية تبقى الشخصية الرابعة كما هي (لا يُحذف شيء)، لكن لا يستطيع إنشاء شخصية جديدة حتى يصير عنده أقل من 3.
- لم يتغيّر أي سطر في الكود، فقط الإعداد. يحتاج إعادة تشغيل w_creators.

## مختبر أزرار اللعبة `/promptlab` (1.0.10، 2026-11-03، للطاقم فقط)

أداة تجربة مؤقتة تجيب عن الأسئلة المفتوحة قبل أن نبني إخفاء أزرار اللعبة الإنجليزية (الخطة: `ops/local/plans/game-prompts-arabic-spec.md`).
لا تغيّر شيئًا للاعبين: لا تعمل إلا لمن عنده صلاحية `w_creators.admin` (صلاحية لوحة `/servicesadmin`، والرتبة master تملكها)، ومن غيره يكتب الأمر لا يحدث له شيء.
الأزرار التي تعيد حركة اللعبة تبقى على أزرار اللعبة نفسها (E للتفتيش والسلخ، R للحمل، F للتقييد) بقرار المالك.

**قبل أن تبدأ (على سيرفر ريث ستوديو أفضل):** معك سلاح، وقريب منك: حصان ليس لك عند عمود ربط، أهل البلد، كرسي أو مقعد، درج أو خزانة، وحيوان تصيده (دجاجة أو غزال). المدة نحو 10 إلى 15 دقيقة.

**الخطوات:**
1. اكتب في الشات `/promptlab`. تظهر بطاقة «مختبر الأزرار» أسفل اليمين، والتعليمات أعلى الشاشة.
2. اقرأ التعليمات وقف حيث تقول، ثم اضغط **J** لتبدأ التجربة. (إذا لم تجد ما تطلبه التجربة اضغط **Z** لتتخطاها.)
3. أثناء التجربة انظر إلى زر اللعبة الإنجليزي وجرّب الزر المذكور في التعليمات. العدّ التنازلي في عنوان البطاقة، و**J** ينهيها قبل الوقت.
4. بعدها يظهر سؤال واحد: **J = نعم**، **G = لا**، **Z = أعد التجربة** (مثلًا لتجربها بيد التحكم أو في مكان آخر).
5. تنتقل وحدها للتجربة التالية. للإنهاء في أي وقت: اضغط **BACKSPACE** مطولًا، أو اكتب `/promptlab` مرة ثانية.
6. في النهاية يظهر **رمز** (مثل `PL-3F2A`) وملخص الإجابات: صوّر الشاشة وأرسل الصورة. ثم J يغلقها.
7. للبدء من تجربة معيّنة: `/promptlab 13` مثلًا.

**أين تذهب النتائج:** كل إجابة تُحفظ فورًا في السيرفر في الملف `promptlab.jsonl` داخل مجلد w_creators (لا يُرفع إلى GitHub). وفي النهاية يكتب السيرفر سطرًا واحدًا في الكونسول يبدأ بـ `[w_creators] PROMPTLAB` ومعه الرمز. لا فيه اسم ولا هوية كاملة (رقم اللاعب في السيرفر وآخر 4 حروف من الرخصة فقط).

| التجربة | المكان | ماذا نعرف منها |
|---|---|---|
| 01-03 | حصان ليس لك | هل الرقم 12 يخفي زر الركوب؟ هل يرجع الركوب وحده تحت الإخفاء الكامل؟ هل يركب بزرّنا E؟ |
| 04-06 | الحصان نفسه (تصويب) | معنى true و false في إخفاء زر المعلومات عن حصان واحد، والرقم 7 لأزرار التصويب |
| 07-08 | شخص من أهل البلد | تحت بطاقة «حديث»: هل F يضرب و 1 يعمل الإيموت؟ |
| 09-10 | شخص من أهل البلد | التقييد وفك الحبل بزرّنا F |
| 11-13 | جثة لم تُفتَّش | هل زر التفتيش ظاهر، هل الرقم 3 يخفيه، هل يفتّش بزرّنا E |
| 14-15 | حيوان ميت | هل الرقم 3 يخفي السلخ، وهل السلخ بزرّنا E يعطي غنائم الجزار |
| 16-19 | حيوان ميت (حمل) | إخفاء زر الحمل بطريقتين، الحمل بزرّنا R، وإخفاء زر الإنزال |
| 20-21 | كرسي | هل الرقم 8 يخفي الجلوس، وهل يجلس بزرّنا E |
| 22 | درج أو خزانة | هل الرقم 2 يخفي زر الفتح |
| 23 | أي زر للعبة | تمر الأرقام 1 إلى 20، واضغط J كلما اختفى الزر |

كل تغيير يبقى (إخفاء زر عن حصان، أو علامة على حيوان) يرجع كما كان في نهاية تجربته، وفي نهاية المختبر، وعند إيقاف المورد.
الإزالة لاحقًا: احذف الملفات `client/lab/promptlab.lua` و `client/natives/promptlab.lua` و `server/lab/promptlab.lua` و `tests/test_promptlab.py` وسطورها الثلاثة في `fxmanifest.lua`، ومفاتيح نصوصها من `locales`.

## أزرار التركيز على شخص (1.0.9، 2026-11-03)

- أزرار اللعبة نفسها (الإيموت، الضرب، اسم «Stranger») كانت تظهر تحت أزرارنا. صارت تختفي ما دامت بطاقتنا ظاهرة، وبطاقتنا فيها أربعة: تحية R، استفزاز G، ضرب F، إيموت 1.
- الضرب والإيموت يبقيان على أزرار اللعبة نفسها وتنفذهما اللعبة. الاستفزاز انتقل من F إلى G لأن F زر الضرب.
- وقت العراك أو المسكة تختفي بطاقتنا وترجع أزرار اللعبة كما هي (مثل 1.0.7).
- التجربة: ركّز على شخص (زر الفأرة الأيمن) وتأكد أن بطاقة واحدة تظهر بأربعة أزرار بلا شيء تحتها، وأن R يحيّي وG يستفز وF يضرب و1 يفتح الإيموت.

## التحية والاستفزاز (1.0.7، 2026-11-02)

- زرّا «تحية» و«استفزاز» عند التركيز على شخص صارا يظهران بإطار w_lib في أسفل اليمين، فالكلام العربي واضح (كان خط اللعبة يرسمه مربعات).
- لا يظهر الزرّان ولا يتغيّر شيء في اللعبة أثناء العراك أو المسكة: كانا يأخذان أزرار اللعبة نفسها، فلم يكن اللاعب يستطيع أن يفك من أمسكه.
- الأزرار كما هي: R للتحية و F للاستفزاز (تتغير الحروف المرسومة من config/voice.lua).
- التجربة في اللعبة: ركّز على شخص (زر الفأرة الأيمن) وتأكد أن «تحية» و«استفزاز» واضحان وأنهما يعملان. ثم أمسك شخصًا وتأكد أن الزرين يختفيان وأنك تستطيع فكّه.

## مكان الظهور للشخصية القديمة (1.0.15، 2026-11-05)

طلب المالك: اللاعب العائد لا يختار أي مدينة يريد.
- **الشخصية القديمة** (الدخول وتبديل الشخصية) ترى في الشاشة «آخر مكان» فقط، ولا تظهر المدن.
- **صاحب البيت** يرى «آخر مكان» و«بيتي» فقط.
- إذا لم يكن له آخر مكان صالح: يرى «بيتي» إن كان يملك بيتًا، وإلا يرى مكان ظهور واحدًا فقط (أول مكان مفعّل في الإعدادات).
- **الشخصية الجديدة** تختار من المدن كما كانت.
- السيرفر يرفض أي مكان لم يُعرض على اللاعب، فلا يمكن تجاوز ذلك من جهة اللاعب.
- الظهور ما زال يمر عبر الشاشة (`direct = false`)، وليس عبر الظهور المباشر الذي سبّب الكراش في 2026-11-04.

ما يحتاج تجربة داخل اللعبة:
1. شخصية قديمة بلا بيت: تظهر «آخر مكان» وحدها، ثم تظهر فيه.
2. صاحب بيت: يظهر «آخر مكان» و«بيتي» فقط.
3. شخصية جديدة: تظهر المدن.

## مكان الظهور والبيت (1.0.8، 2026-11-02)

- **الشخصية الجديدة** تختار مكان ظهورها من شاشة المدن كما كانت.
- **كل دخول بعد ذلك** (الدخول وتبديل الشخصية) يظهر اللاعب مباشرة في **آخر مكان** كان فيه، بلا شاشة اختيار. إذا كان آخر مكان غير صالح (خارج الخريطة أو صفر أو في مسرح الإنشاء) تفتح شاشة المدن.
- **صاحب البيت** (المالك فقط، لا من معه مفتاح) يختار من اثنين: «آخر مكان» أو «بيتي». «بيتي» = على سرير بيته، يستلقي ثم ينهض بحركة اللعبة نفسها (سيناريو `PROP_HUMAN_SLEEP_BED_PILLOW` وخروجه، مقاطع اللعبة `amb_rest@prop_human_sleep_bed@pillow@male_a` / `female_a@stand_exit`). إذا لم يكن في البيت سرير يظهر داخل الباب. إذا لم يكن له آخر مكان صالح: «بيتي» مع المدن.
- البيت يأتي من w_housing (`GetHomeSpawn`)، والسيرفر يسأله من جديد عند الاختيار (لو بِيع البيت في هذه الأثناء يُرفض الاختيار ويبقى الاختيار الآخر). إذا لم يعمل w_housing يظهر اللاعب في آخر مكان كأن لا بيت له.
- الإعدادات في `config/spawn.lua`: `Config.Spawn.lastLocation.direct` (false = شاشة المدن لكل دخول كما قبل 1.0.8)، و`Config.Spawn.home` (`enabled`، `wakeMs` مدة الاستلقاء قبل النهوض).
- **خزانة البيت:** خزانة الملابس الموضوعة في البيت تفتح ملابس الشخصية (`home:<رقم القطعة>`). السيرفر يسأل w_housing (`CanUseWardrobe`) عند الفتح وعند كل حفظ: المالك أو من معه مفتاح، واقف عند القطعة. هذا يعمل حتى لو أُوقفت الخزائن عن بُعد (`Config.Wardrobe.allowRemote`).
- الموت لم يتغير هنا (w_medic يرسل الميت لأقرب مستشفى من الخمسة).
- **إصلاح المراجعة قبل النشر:** صاحب البيت يرى دائمًا «آخر مكان» ثم «بيتي» مهما كان `Config.Spawn.lastLocation.preselect`.
- الاختبارات: `py -3 -I -m unittest discover -s tests` = 1572، والأخطاء القديمة نفسها فقط (56 الآن، لا جديد). ستة اختبارات قديمة كانت تفحص شاشة المدن لكل دخول صارت تضبط `direct = false` لأنها تفحص ذلك الخيار.

ما يحتاج تجربة داخل اللعبة:
1. شخصية جديدة: شاشة المدن تظهر.
2. اخرج وادخل بشخصية قديمة بلا بيت: تظهر مكانك مباشرة بلا شاشة.
3. صاحب بيت فيه سرير: يظهر «آخر مكان» و«بيتي». اختر «بيتي»: تظهر على السرير مستلقيًا ثم تنهض. تأكد أن الاستلقاء على السرير نفسه وليس بجانبه أو تحته.
4. صاحب بيت بلا سرير: «بيتي» يضعك داخل الباب.
5. من معه مفتاح فقط: لا يظهر له «بيتي».
6. خزانة الملابس في البيت: J تفتح ملابسك وتحفظ، ومن ليس معه مفتاح يُرفض.

## الملفات

العقد الملزم وتخطيط الملفات وترتيب التحميل في `docs/ARCHITECTURE.md` (§2).

- `shared/`: نموذج المظهر v3 (`shared/appearance.lua`)، الكتالوج والقواعد، الهوية، النمو، حالات الملابس.
- `client/appearance/`: مسار التطبيق الواحد (`pipeline.lua`)، الطبقات، ومزامنة مظاهر اللاعبين.
- `client/editor/`: جلسة المحرر وشجرة العقد (`tree.lua`) واللوحة الخفيفة.
- `client/scene/` و`server/scene.lua`: مشهد المعاينة، والعزل المحروس من السيرفر.
- `server/characters/characters.lua`: قائمة الشخصيات والاختيار والإنشاء والحذف.
- `server/spawn/spawn.lua` و`server/respawn/respawn.lua`: مواقع الظهور وإعادة الإظهار.
- `server/clothing/` و`server/wardrobe/`: المتجر والملكية والأزياء وحالات الملابس.
- `server/barber/` و`server/surgery/`: الحلاق وعداد النمو وعيادة التجميل.
- `server/api.lua`: الـexports العامة (§13).
- `web/src/`: React، و`web/build/`: الواجهة المبنية المستخدمة في اللعبة.

## التشغيل والتطوير

شغّل قاعدة البيانات ثم `w_lib` ثم إطار العمل ثم `w_creators`. تُنشأ جداول المورد تلقائيًا دون استيراد يدوي جديد. يحتفظ `server/bridge/framework.lua` بتوافق دورة الشخصية مع Wraith/VORP/RSG/QBR.

لتطوير الواجهة، داخل `web` استخدم `npm install` ثم `npm run dev` أو `npm run build`. لا توجد iframes أو صفحة متجر منفصلة.

بعد تحديث ملفات المكتبة والـmanifest يلزم إعادة تشغيل السيرفر ثم إعادة الاتصال. لا تعِد تشغيل المنشئ أثناء تعديل لاعب لشخصيته. الاختبارات الآلية (Python وواجهة NUI) وخطوات الاختبار داخل اللعبة مع النتائج المتوقعة في `docs/TESTING.md`؛ لم يُنفَّذ أي منها بعد على سيرفر RedM حي.

اللوقات اختيارية عبر `server/bridge/logging.lua`؛ غياب مورد اللوقات لا يمنع اختيار الشخصية أو الظهور. الاعتمادات في `CREDITS.md`.

---

## English

### What w_creators owns

w_creators v3 is the server authority for the whole character lifecycle: account → characters
(selection, creation, deletion, switching) → identity → persistent appearance → clothing ownership →
saved outfits → runtime clothing states → barber (hair/beard growth: off since 1.0.5) → cosmetic surgery → spawn →
respawn after death. The binding contract is `docs/ARCHITECTURE.md`; the public integration surface
is `docs/API.md`.

Replace any other multicharacter / spawn / character-creator resource: w_creators always shows the
selection screen, registers new characters in the framework and spawns the player.

### Dependencies and start order

```
ensure oxmysql
ensure w_lib
ensure <framework>          # w_core (via w_lib), vorp_core, rsg-core or qbr-core
ensure w_creators
ensure w_ambulancejob       # optional
```

- **Required:** OneSync (`/onesync` in the manifest), `oxmysql` (`@oxmysql/lib/MySQL.lua`),
  `w_lib` (it must be the first shared script; the manifest preloads its `locale`, `component` and
  `callback` modules), and a framework. `server/bridge/framework.lua` picks the framework through
  w_lib first, then `Config.Framework` (`'auto'` | `'vorp'` | `'rsg'` | `'qbr'`), then whichever of
  `vorp_core` / `rsg-core` / `qbr-core` is started.
- **Optional:** `w_ambulancejob` (death system and cosmetic-surgery prompts: it calls
  `exports.w_creators:Resurrect` and `exports.w_creators:OpenCosmeticSurgery`, each only while
  `GetResourceState('w_creators') == 'started'`), `w_loading` (loading curtain), `w_logs` (logging
  through `server/bridge/logging.lua`; if it is missing, selection and spawn still work),
  `w_centralbank` (cash/bank/gold shown on the rsg/qbr character card when it is ready).

### Install

1. Copy the resource and add the `ensure` lines in the order above.
2. Database: nothing to import. On start `server/core/migrations.lua` runs the additive,
   idempotent migrations `001_base_tables`, `002_appearance_v3`, `003_clothes_meta` and `004_outfits`, and records them in
   `w_creators_migrations`. It never drops anything. `sql/install.sql` is the same end state for a
   manual install and records no migration id, so the resource still checks every step on its next
   start.
3. NUI: `web/build/` ships built. To rebuild it, run `cd web && npm install && npm run build`.
4. Set up `config/*.lua` (next section). Restart the whole server after you change the manifest
   or w_lib.

### Configuration map

| File | Tables | What you change there |
|---|---|---|
| `config/main.lua` | `Config.Debug`, `Config.Framework`, `Config.Services`, `Config.Characters`, `Config.Creator`, `Config.Scene`, `Config.Experimental`, `Config.Keys`, `Config.Admin` | service toggles, slots, deletion, identity rules, selection/gender prompts, creator stages and cutscene, the creator room, research flags (all off), keys, admin ACEs and dev tools |
| `config/locations.lua` | `Config.LocationDefaults`, `Config.Locations` | every clothing store, wardrobe, barber and surgery clinic: `id`, `type`, `enabled`, `coords`, `interactionRadius`, `npc`, `blip`, `prompt`, `preview`, `camera`, `storeProfile`, `pricingProfile`, `allowedServices`, `hours`, `book` (the store's catalogue book), `outfits`, `access` (jobs / ACE) |
| `config/clothing.lua` | `Config.Clothing` (`taxonomy`, `prices`, `modelPrices`, `payment`, `tints`, `storeProfiles`, `pricingProfiles`, `resell`, `suggestions`, `fittingLight`, `catalogue`, `items`, `applyOrder`, `rules`, `essentialNotRemovable`), `Config.ClothingStates` (+ `commands`, `bandanaStateBag`) | the category tree, prices per category and per model, in cash or gold (a negative or missing price means not for sale), tint palettes, limits and price, selling back, the tailor's suggestions, the fitting-room light, the catalogue book, the optional inventory items, conflicts, clothing-state groups and their commands |
| `config/barber.lua` | `Config.Barber`, `Config.Grooming` | barber service prices and `prices.visitCap`; growth (`enabled = false` since 1.0.5), its stages, `minutesPerStage`, `saveIntervalSeconds` |
| `config/surgery.lua` | `Config.CosmeticSurgery` | `price`, `allow` (sections a procedure may change), `sessionMinutes` |
| `config/wardrobe.lua` | `Config.Wardrobe` | `maxSavedOutfits`, `outfitNameMax`, `allowRemote` |
| `config/spawn.lua` | `Config.Spawn`, `Config.Respawn` | `firstSpawn`, selector, camera, `lastLocation`, `snapToGround`, `bounds`, `sceneExclusionRadius`, `points` (`id`, `enabled`, `order`, `coords`, `heading`, `cam`); respawn polling/restore |
| `config/outfits.lua` | `Config.Creator.startingClothing`, `Config.StartingOutfits` | creator clothing stage: `mode = 'free'` or `'presets'` |

**Service toggles** (`Config.Services`): `characterCreation`, `characterDeletion`, `clothingStores`,
`barbers`, `surgery`, `wardrobe`, `savedOutfits`, `clothingActions`, `spawnSelector`, `lastLocation`,
`deathRespawn`. A disabled service shows no prompts, blips or NPCs, and its server callbacks answer
`SERVICE_DISABLED` or the service's `*_DISABLED` code. Some settings copy a toggle and need it to be on
too: `Config.Characters.deletion.enabled` (deletion needs both), `Config.Spawn.selector.enabled`,
`Config.Spawn.lastLocation.enabled`, `Config.ClothingStates.enabled`.

**Per location / per point:** set `enabled = false` on a `Config.Locations` entry to hide it. The
server then refuses it (`LOCATION_DISABLED`), and so does an entry outside its `hours`. Set
`enabled = false` on a `Config.Spawn.points` entry to hide the point; the server then refuses it
(`INVALID_SPAWN`). To add a shop, add a `Config.Locations` entry; no code change is needed. Clinics
use `prompt = false` because w_ambulancejob shows their prompt. Keep w_ambulancejob's
`Config.CosmeticSurgery.clinics[].clinicId` equal to these ids, and put its prompt coordinates close
to the clinic `coords`. The server allows `interactionRadius + 3` metres.

Prices, ownership, slots, identity, spawn coordinates and service availability come only from these
files and the database. No price or coordinate is ever read from the client.

### Commands and keybinds

| Command / key | Where | Condition |
|---|---|---|
| `Config.Keys.interact` (`J`) | service locations | location `prompt = true` |
| `Config.Characters.selection.keys` (`RETURN`, `DELETE` held `deletion.holdTime` ms, `LEFT`, `RIGHT`) | selection screen | — |
| `Config.Characters.genderPrompt` (`LEFT` = the man, `RIGHT` = the woman: opens the editor at once; `BACK`) | creator gender scene | the editor's root Back ("change the sex") returns to it and keeps both drafts |
| `Config.Spawn.selector.keys` (`RETURN`, `LEFT`, `RIGHT`; `cancel`, default `BACK`) | spawn selector | `cancel` only for an in-world selector (kinds `admin` / `death`) |
| `/characters` | client | `Config.Characters.allowSwitch = true`; refused while dead, in an editor or a session |
| `/clothing`, keybind `wc_clothing_actions` (default `Config.Keys.clothingActions`, `nil` = unbound) | client | `Config.Services.clothingActions` |
| `/reloadappearance` | client | re-reads the saved appearance (server rate limit: 1 per 10 s) |
| `wc_respawn <citizenId> [pointId]` | server console or `Config.Admin.ace` | the target's citizen id (`#5` = whoever is on server id 5; he must be in the game); `pointId` = a point id, `__last`, or omitted (first enabled point) |
| `wc_migrate_appearances` | server console only | upgrades every legacy appearance row in batches of 100 |
| `wc_catalog_validate` | server console or `Config.Admin.devAce` | `Config.Admin.devTools = true` |
| `wc_inspect`, `wc_apply <hash>`, `wc_remove <category>`, `wc_restore` | client, `Config.Admin.devAce` | `Config.Admin.devTools = true`; local ped only |
| `spawnprop <model>` | ACE `command.spawnprop` | `Config.Admin.spawnProp = true` |
| `/promptlab [n]` | client, `Config.Admin.ace` (checked by the server on open and on every report) | the staff's game prompts lab (1.0.10): 23 guided tests, answers to `promptlab.jsonl` + one `PROMPTLAB` console line |

Editor navigation (same in every mode): up/down arrows move, Enter opens, Escape goes back one
level (from the root it asks to confirm the cancel). Drag rotates the character, the wheel zooms,
right click resets the view, and a click on a body part zooms to it.

### Upgrading from pre-v3

The pre-v3 files `config.lua`, `data/stores.lua`, `data/grooming.lua`, `data/*.lua`, `bridge/`,
`creator/`, `multichar/`, `spawnselect/`, `store/` and `sql/characters_appearence.sql` are removed.
Copy your values into the new keys:

| Pre-v3 | v3 |
|---|---|
| `Config.FirstSpawnCoords`, `Config.FirstSpawnHeading` | `Config.Spawn.firstSpawn.coords`, `.heading` |
| `Config.SpawnPoints[]` (`id`, `label`, `region`, `coords`, `heading`, `cam`) | `Config.Spawn.points[]`, same fields plus `enabled`, `order` |
| `Config.SpawnSelector` | `Config.Services.spawnSelector` (`Config.Spawn.selector.enabled` copies it) |
| `Config.SpawnLastOption` | `Config.Services.lastLocation` (`Config.Spawn.lastLocation.enabled` copies it; `.preselect`) |
| `Config.SpawnSnapToGround` | `Config.Spawn.snapToGround` |
| `Config.SpawnTransition`, `Config.SpawnSceneTimeout` | `Config.Spawn.selector.transition`, `.sceneTimeout` |
| `Config.SpawnCamDefaults` | `Config.Spawn.camera` |
| `Config.SpawnSelectKeys`, `Config.SpawnSelectPromptPosition`, `Config.SpawnSelectLabels` | `Config.Spawn.selector.keys`, `.promptPosition`, `.labels` |
| `Config.CharacterSlots` | `Config.Characters.defaultSlots` (plus `slotPermissions` by ACE) |
| `Config.EnableDelete` | `Config.Services.characterDeletion` and `Config.Characters.deletion.enabled` |
| `Config.DeleteHoldTime` | `Config.Characters.deletion.holdTime` |
| `Config.SelectionKeys`, `Config.SelectionPromptPosition`, `Config.SelectionLabels` | `Config.Characters.selection.keys`, `.promptPosition`, `.labels` |
| `Config.GenderPrompt` | `Config.Characters.genderPrompt` |
| `Config.CharactersTable` | `Config.Characters.tables` |
| `Config.SetSurvivalMetadata` | `Config.Characters.setSurvivalMetadata` |
| `Config.EnableCutscene` | `Config.Creator.enableCutscene` (ride coordinates: `Config.Creator.cutscene`) |
| `Config.SpawnEvent` | `Config.Creator.spawnEvent` |
| `Config.Multicharacter` | removed: w_creators is always the multicharacter |
| `Config.SceneImaps`, `SceneLoadSphere`, `SceneAnchor`, `SceneLights`, `SceneScenarios`, `SceneWeapon`, `SceneCleanupRadius` | `Config.Scene.imaps`, `.loadSphere`, `.anchor`, `.lights`, `.scenarios`, `.weapon`, `.cleanupRadius` |
| `Config.ScenePeds` (`[1]` male, `[2]` female) | `Config.Scene.peds.male`, `.female` |
| `Config.EditingPed`, `Config.SelectionPed` | `Config.Scene.editingPed`, `.selectionPed` |
| `StoreData.stores[]` (`town`, `book`, `fittingRoom`, `ped`, `blip`) | `Config.Locations` entries with `type = 'clothing'`: `id`, `town`, `coords` (the book's x/y/z), `preview` (the fitting room), `npc = { model, coords }`, `blip` |
| `StoreData.wardrobes[]` (`coords`, `blip`) | `Config.Locations` entries with `type = 'wardrobe'` (`rhodes_wardrobe`, `valentine_wardrobe`, `saintdenis_wardrobe`) |
| `StoreData.prices` (`-1` = not sold) | `Config.Clothing.prices` (negative or missing = not sold); per-store `pricingProfile` multiplier |
| `StoreData.categoryNames` | `label` of each `Config.Clothing.taxonomy` subcategory |
| `StoreData.colorPrice` | `Config.Clothing.tints.price` |
| `StoreData.palettes` (`tint_*`) | `Config.Clothing.tints.default` / `.palettes[category]` (`metaped_tint_*` names from w_lib) |
| `StoreData.openKey` | `Config.Keys.interact` |
| `StoreData.promptDistance` | `interactionRadius` (per location or `Config.LocationDefaults`) |
| `GroomingConfig.enabled`, `.minutesPerStage`, `.stages` | `Config.Grooming.enabled`, `.minutesPerStage`, `.stages` |
| `GroomingConfig.price` (flat 10) | `Config.Barber.services.{hair,facialHair,details}.price` capped by `Config.Barber.prices.visitCap` (defaults 10 / 10 / 5, cap 10: the old flat price) |
| `GroomingConfig.barbers[]` (`town`, `coords`) | `Config.Locations` entries with `type = 'barber'` (`valentine_barber`, `blackwater_barber`, …) |

**Characters migrate lazily.** A pre-v3 row (`appearance_version < 3` or no `appearance` JSON) is
converted when it is first loaded. It is written back as v3 only if the conversion needed no
default for the head, eyes, teeth or body. In the same transaction the equipped clothing is granted
as owned (`source = 'legacy'`). A row that needed defaults is not rewritten and a warning is logged.
To convert everything at once, run `wc_migrate_appearances` in the server console.

**Rollback.** Stop v3 and put back the pre-v3 release together with its `config.lua` and `data/*.lua`.
No database restore is needed. Every v3 save also rewrites the legacy columns
(`isMale`, `components`, `faceFeatures`, `overlays`), so the old release can still load every
character. The v3-only data (the `appearance` JSON, tints, clothing states, `w_creators_outfits`,
`w_creators_clothes.source` / `acquired_at`) is left in place and the old release ignores it. When
you upgrade again, v3 notices rows that the old release wrote in the meantime (legacy-column
fingerprint) and rebuilds them from those columns. Tints of items that changed are lost. Do not
edit the legacy columns by hand on a v3 row: a valid edit replaces the v3 appearance on the next load.
The fingerprint rebuild is covered by unit tests (`RollbackTests` in
`tests/test_review_server_r1.py`). Running the pre-v3 release against a v3 database requires live
verification.

### Documentation

| File | Contents |
|---|---|
| `docs/ARCHITECTURE.md` | binding contract: modules, data model, callbacks/events (§16), security (§14) |
| `docs/API.md` | exports, public events, compatibility shims, integration rules |
| `docs/TESTING.md` | automated suites and the live RedM test matrix |
| `docs/NATIVES.md` | every native wrapper with its confidence level |
| `docs/NUI_CONTRACT.md` | pointer to the NUI contract (§8) |
| `sql/install.sql` | reference schema |
| `CREDITS.md` | credits |

The automated suites run outside the game. Nothing has run on a live RedM server yet. Every
engine-dependent behaviour in these documents still requires live verification (`docs/TESTING.md`).

## 1.0.4 — 2026-10-30

- تصحيح اسم الشامات في محرر المظهر، مع إبقاء مفاتيح الترجمة القديمة للتوافق.
- حفظ إيصال دائم قبل أي خصم في المتجر والحلاق والتجميل. إذا فشل الحفظ ولم ينجح رد المال، يبقى المبلغ ظاهرًا كمدفوع ويظهر رقم الإيصال للمستخدم.
- في Wraith Core، تعاد المحاولة للشخصية نفسها فقط إذا لم تبدأ محاولة رد المال أصلًا، مثل تبديل الشخصية قبل الرد. أي رد مالي غير مؤكد يتوقف للمراجعة ولا يصرف مرة ثانية. الحالات غير المؤكدة بعد انقطاع أثناء الخصم أو الرد تتوقف للمراجعة، حتى لا يصرف المال مرتين.
- التخزين محلي في KVP للمورد، دون تعديل قاعدة البيانات. يجب تضمين KVP ضمن النسخ الاحتياطية. الأمر `creatorrefund <character-id> <players-row-id>` من كونسول السيرفر يعرض حالة الإيصال فقط؛ لا ينفذ أي صرف.
- الحالات `prepared` و`charged` و`refunding` و`review` غير المحسومة تحتاج مطابقة رصيد/سجل العملية قبل أي تسوية يدوية. لا تحذف إيصالًا لتجاوز المراجعة.
- تجربة اللعبة المطلوبة: فتح قسم الشامات، ثم شراء ناجح من متجر وحلاق وتجميل في بيئة اختبار. محاكاة الفشل محليًا غطت منع رد المال مرتين وتبديل الشخصية؛ لم يتم تغيير أرصدة حقيقية.

- تقوية ملكية إيصال الاسترداد: يحفظ رقم صف الشخصية الثابت `players.id` وصاحب الحساب، ويعزل الإيصالات عند إعادة استخدام رقم المواطن. يحجز `WithCitizenGeneration` الجيل طوال الخصم والحفظ ورد المبلغ، وعند إعادة المحاولة.
- يتطلب مسار Wraith Core الإصدار 1.0.5 أو أحدث الذي يوفر `WithCitizenGeneration`؛ غياب الحجز يمنع الخصم بأمان. الأطر الأخرى تربط الإيصال بصاحب الحساب، وتحتاج مراجعة يدوية لأي رد غير مؤكد؛ لا تعيد صرفه تلقائيًا.
- استعراض إيصال جيل سابق من الكونسول: `creatorrefund <character-id> <players-row-id>`. هذا للقراءة فقط.

- لا يعامل رد الجسر `false` على أنه رفض مالي مؤكد؛ فقد يخفي نتيجة دفتر غير محسومة. يتحقق الرصيد قبل الخصم، وتمنع إعادة الخصم أو التعويض إذا لم تتأكد نتيجة المحاولة السابقة.

## 1.0.6 — 2026-11-01

- رسائل الرفض في المتاجر والحلاق والخزانة والعيادة تقول السبب:
  - المكان المغلق بسبب ساعات العمل يقول متى يفتح: «مغلق الآن، يفتح من 06:00 إلى 22:00». المكان الذي أوقفته الإدارة يبقى
    «هذا المكان مغلق حاليًا».
  - المكان الخاص بوظيفة يذكر الوظيفة: «هذا المكان خاص بوظيفة: الشريف».
  - نقص المال يذكر السعر وما معك: «السعر 12$ ومعك 5$» (وبالذهب كذلك).
- هذا الملف كان ما زال يشرح نمو الشعر واللحية كأنه يعمل؛ صُحّح: النمو متوقف منذ 1.0.5.

## 1.0.5 — 2026-11-01

- الحلاق: أُوقف نمو الشعر واللحية التلقائي (طلب المالك). الحلاق الآن لاختيار القصة فقط، ولا تتغير القصة وحدها بعد ذلك. من تغيّرت قصته سابقًا بسبب النمو يختار قصته من جديد عند الحلاق.
- متجر الملابس والخزانة: إذا كان أمام الكاميرا جدار، تنتقل الكاميرا إلى الجهة الأخرى من اللاعب أو تقترب منه أمام الجدار، فيبقى اللاعب ظاهرًا (مثل غرفة فندق فالنتاين بالعربية وكابينة تمبلويد). المتاجر التي لا جدار فيها أمام الكاميرا لم تتغير.
- لون اللحية: تغيير اللون يبقي شكل اللحية نفسه. «اللحية 19» القديمة كانت ست لحى مختلطة، وصارت ست لحى بأسمائها (لحية مضفورة بالخرز، لحية القوس، لحية المقبض، لحية المستنير، لحية الشقّين، لحية الياقة)، ولكل واحدة ألوانها بأسمائها. ولحيتان لا يُعرف اسمهما صارت كل واحدة منهما بندًا مستقلًا («اللحية 25» و«اللحية 26»). اللحى المحفوظة سابقًا تبقى كما هي.
