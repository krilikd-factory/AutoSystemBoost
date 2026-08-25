#!/system/bin/sh

MODDIR="${MODDIR:-${0%/*}}"

# Section headings in the device's language.
#
# This screen had no localisation at all - every heading was English regardless of the
# phone's locale, while the installer and the WebUI were translated. Headings only: the
# detail lines under them carry measured values and unit names, and translating those
# badly would make a diagnostic report misleading rather than merely foreign.
_asb_loc="$(settings get system system_locales 2>/dev/null)"
[ -z "$_asb_loc" ] || [ "$_asb_loc" = "null" ] && _asb_loc="$(getprop persist.sys.locale 2>/dev/null)"
case "$(printf '%s' "$_asb_loc" | tr '[:upper:]' '[:lower:]')" in
  *ru-*|*ru_*|ru) H_AUDIO="АУДИО"; H_CAMERA="КАМЕРА"; H_MEMORY="ПАМЯТЬ"; H_NETWORK="СЕТЬ"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="СИСТЕМА"; H_IFACE="ИНТЕРФЕЙС"
                  H_SLEEP="СОН"; H_LEARN="ОБУЧЕНИЕ"; H_SMART="ЧТО ВЫУЧИЛ SMART"
                  H_GOV="РЕГУЛЯТОР ЧАСТОТ"; H_BATT="АВТО-БАТАРЕЯ"; H_LPM="МОДЕМ LPM" ;;
  *uk-*|*uk_*|uk) H_AUDIO="АУДІО"; H_CAMERA="КАМЕРА"; H_MEMORY="ПАМʼЯТЬ"; H_NETWORK="МЕРЕЖА"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="СИСТЕМА"; H_IFACE="ІНТЕРФЕЙС"
                  H_SLEEP="СОН"; H_LEARN="НАВЧАННЯ"; H_SMART="ЩО ВИВЧИВ SMART"
                  H_GOV="РЕГУЛЯТОР ЧАСТОТ"; H_BATT="АВТО-БАТАРЕЯ"; H_LPM="МОДЕМ LPM" ;;
  *de-*|*de_*|de) H_AUDIO="AUDIO"; H_CAMERA="KAMERA"; H_MEMORY="SPEICHER"; H_NETWORK="NETZWERK"
                  H_WIFI="WLAN"; H_GPS="GPS"; H_SYSTEM="SYSTEM"; H_IFACE="OBERFLÄCHE"
                  H_SLEEP="SCHLAF"; H_LEARN="LERNEN"; H_SMART="WAS SMART GELERNT HAT"
                  H_GOV="GOVERNOR"; H_BATT="AUTO-AKKU"; H_LPM="MODEM LPM" ;;
  *es-*|*es_*|es) H_AUDIO="AUDIO"; H_CAMERA="CÁMARA"; H_MEMORY="MEMORIA"; H_NETWORK="RED"
                  H_WIFI="WIFI"; H_GPS="GPS"; H_SYSTEM="SISTEMA"; H_IFACE="INTERFAZ"
                  H_SLEEP="SUEÑO"; H_LEARN="APRENDIZAJE"; H_SMART="LO QUE SMART HA APRENDIDO"
                  H_GOV="REGULADOR DE FRECUENCIA"; H_BATT="BATERÍA AUTO"; H_LPM="MÓDEM LPM" ;;
  *pt-*|*pt_*|pt) H_AUDIO="ÁUDIO"; H_CAMERA="CÂMERA"; H_MEMORY="MEMÓRIA"; H_NETWORK="REDE"
                  H_WIFI="WIFI"; H_GPS="GPS"; H_SYSTEM="SISTEMA"; H_IFACE="INTERFACE"
                  H_SLEEP="SONO"; H_LEARN="APRENDIZADO"; H_SMART="O QUE O SMART APRENDEU"
                  H_GOV="REGULADOR DE FREQUÊNCIA"; H_BATT="BATERIA AUTO"; H_LPM="MODEM LPM" ;;
  *tr-*|*tr_*|tr) H_AUDIO="SES"; H_CAMERA="KAMERA"; H_MEMORY="BELLEK"; H_NETWORK="AĞ"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SİSTEM"; H_IFACE="ARAYÜZ"
                  H_SLEEP="UYKU"; H_LEARN="ÖĞRENME"; H_SMART="SMART NE ÖĞRENDİ"
                  H_GOV="GOVERNOR"; H_BATT="OTO PİL"; H_LPM="MODEM LPM" ;;
  *in-*|*id-*|*id_*|id) H_AUDIO="AUDIO"; H_CAMERA="KAMERA"; H_MEMORY="MEMORI"; H_NETWORK="JARINGAN"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SISTEM"; H_IFACE="ANTARMUKA"
                  H_SLEEP="TIDUR"; H_LEARN="PEMBELAJARAN"; H_SMART="YANG DIPELAJARI SMART"
                  H_GOV="GOVERNOR"; H_BATT="BATERAI OTOMATIS"; H_LPM="MODEM LPM" ;;
  *fr-*|*fr_*|fr) H_AUDIO="AUDIO"; H_CAMERA="APPAREIL PHOTO"; H_MEMORY="MÉMOIRE"; H_NETWORK="RÉSEAU"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SYSTÈME"; H_IFACE="INTERFACE"
                  H_SLEEP="SOMMEIL"; H_LEARN="APPRENTISSAGE"; H_SMART="CE QUE SMART A APPRIS"
                  H_GOV="RÉGULATEUR DE FRÉQUENCE"; H_BATT="BATTERIE AUTO"; H_LPM="MODEM LPM" ;;
  *hy-*|*hy_*|hy) H_AUDIO="ՁԱՅՆ"; H_CAMERA="ՏԵՍԱԽՑԻԿ"; H_MEMORY="ՀԻՇՈՂՈՒԹՅՈՒՆ"; H_NETWORK="ՑԱՆՑ"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="ՀԱՄԱԿԱՐԳ"; H_IFACE="ԻՆՏԵՐՖԵՅՍ"
                  H_SLEEP="ՔՈՒՆ"; H_LEARN="ՈՒՍՈՒՑՈՒՄ"; H_SMART="ԻՆՉ Է ՍՈՎՈՐԵԼ SMART-Ը"
                  H_GOV="ՀԱՃԱԽՈՒԹՅԱՆ ԿԱՐԳԱՎՈՐԻՉ"; H_BATT="ԱՎՏՈ ՄԱՐՏԿՈՑ"; H_LPM="ՄՈԴԵՄ LPM" ;;
  *it-*|*it_*|it) H_AUDIO="AUDIO"; H_CAMERA="FOTOCAMERA"; H_MEMORY="MEMORIA"; H_NETWORK="RETE"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SISTEMA"; H_IFACE="INTERFACCIA"
                  H_SLEEP="SONNO"; H_LEARN="APPRENDIMENTO"; H_SMART="COSA HA IMPARATO SMART"
                  H_GOV="GOVERNOR"; H_BATT="BATTERIA AUTO"; H_LPM="MODEM LPM" ;;
  *ar-*|*ar_*|ar) H_AUDIO="الصوت"; H_CAMERA="الكاميرا"; H_MEMORY="الذاكرة"; H_NETWORK="الشبكة"
                  H_WIFI="واي فاي"; H_GPS="GPS"; H_SYSTEM="النظام"; H_IFACE="الواجهة"
                  H_SLEEP="النوم"; H_LEARN="التعلّم"; H_SMART="ما تعلّمه SMART"
                  H_GOV="منظّم التردد"; H_BATT="البطارية التلقائية"; H_LPM="مودم LPM" ;;
  zh-cn*|zh_cn*|*zh-hans*|zh) H_AUDIO="音频"; H_CAMERA="相机"; H_MEMORY="内存"; H_NETWORK="网络"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="系统"; H_IFACE="界面"
                  H_SLEEP="休眠"; H_LEARN="学习"; H_SMART="SMART 学到了什么"
                  H_GOV="频率调节器"; H_BATT="自动电池"; H_LPM="调制解调器 LPM" ;;
  *)              H_AUDIO="AUDIO"; H_CAMERA="CAMERA"; H_MEMORY="MEMORY"; H_NETWORK="NETWORK"
                  H_WIFI="WI-FI"; H_GPS="GPS"; H_SYSTEM="SYSTEM"; H_IFACE="INTERFACE"
                  H_SLEEP="SLEEP"; H_LEARN="LEARNING"; H_SMART="WHAT SMART HAS LEARNED"
                  H_GOV="GOVERNOR"; H_BATT="AUTO BATTERY"; H_LPM="MODEM LPM" ;;
esac

# Body strings, not just headings.
#
# The headings were translated and everything under them was not, which is arguably worse
# than all-English: the screen looks finished until you read a line. These are the
# sentences a user actually reads. Numbers, units and identifiers are left alone - a
# mistranslated unit turns a diagnostic into a wrong reading.
case "$(printf '%s' "$_asb_loc" | tr '[:upper:]' '[:lower:]')" in
  *ru-*|*ru_*|ru)
    M_CONF_LOW="Пока низкая — Smart здесь в основном использует безопасные значения."
    M_CONF_HIGH="Высокая — решения в этом слоте основаны на измерениях, а не на умолчаниях."
    M_DRAIN_NOSAMPLE="расход не замерялся — экран здесь включают ненадолго"
    M_AWAKE="бодрствование во сне"; M_MIN="мин"
    M_AWAKE_BAD="!! телефон не засыпает — это дороже любой настройки здесь"
    M_SLOT="Слот времени"; M_SLOT_OF="из 12"
    M_SLOT_H1="День разбит на 12 слотов, каждый учится отдельно —"
    M_SLOT_H2="в будни утром и в воскресенье вечером телефон ведёт себя по-разному."
    M_CONF="Уверенность в этом слоте"; M_SES_BANK="сессий накоплено всего"
    M_MEASURED="Измерено для этого слота"; M_TYP_PEAK="типичный пик"; M_DRAIN="расход"
    M_NORMAL="Норма для вашего телефона"
    M_ABOVE="Выше"; M_LEANS="Smart склоняется к экономии, ниже"; M_ALLOWS="разрешает чуть больше."
    M_NOTFIXED1="Это не фиксированные числа — это медиана ваших же"
    M_NOTFIXED2="12 слотов, поэтому телефон, который просто горячее, не наказывается."
    M_RIGHTNOW="Сейчас"; M_LEAN_BAT="склоняется к экономии"
    M_LEAN_PERF="склоняется к производительности"; M_LEAN_BAL="сбалансировано"
    M_TOUCH_BOOST="плюс короткий подъём при касании экрана"
    M_WATCHING="Наблюдает сейчас"; M_APP="приложение"
    M_IDLE="простой"; M_LIGHT="лёгкая нагрузка"; M_NORMAL_USE="обычная нагрузка"
    M_HEAVY="высокая нагрузка"; M_GAMING="игра"
    M_REMEMBERS="Помнит тепловое поведение приложений:"; M_APPS=""
    M_PREDICT="Прогноз времени экрана"; M_AT_RATE="при текущем расходе"
    M_NOTE_PARTIAL="Примечание: работает на неполных данных для этого слота"
    M_NOTE_NEIGHBOUR="Примечание: используется соседний слот"
    M_NOTE_NODATA="Примечание: истории пока нет — безопасные значения"
    M_DISCARDED="сессий отброшено как ненадёжные"
    M_THIS_HOUR="в этот час обычно"
    M_WARM_HERE="тепло для этого телефона — Smart склоняется к экономии"
    M_COOL_HERE="прохладно для этого телефона — Smart разрешает чуть больше"
    M_SES_LEARNED="сессий изучено"; M_DRAIN_NOW="расход сейчас"
    M_BANKED="накоплено — Smart не управляет на этом профиле"
    M_DP0="ночь"; M_DP1="раннее утро"; M_DP2="утро"; M_DP3="день"; M_DP4="вечер"; M_DP5="поздний вечер"
    M_WEEKEND="выходной"; M_WEEKDAY="будний день"
    M_FOREGROUND="активное приложение" ;;
  *uk-*|*uk_*|uk)
    M_CONF_LOW="Поки низька — Smart тут переважно використовує безпечні значення."
    M_CONF_HIGH="Висока — рішення в цьому слоті базуються на вимірюваннях, а не на умовчаннях."
    M_DRAIN_NOSAMPLE="витрата не вимірювалась — екран тут вмикають ненадовго"
    M_AWAKE="неспання уві сні"; M_MIN="хв"
    M_AWAKE_BAD="!! телефон не засинає — це дорожче за будь-яке налаштування тут"
    M_SLOT="Слот часу"
    M_SLOT_OF="із 12"
    M_SLOT_H1="День поділено на 12 слотів, кожен вчиться окремо —"
    M_SLOT_H2="у будні вранці й у неділю ввечері телефон поводиться по-різному."
    M_CONF="Впевненість у цьому слоті"
    M_SES_BANK="сесій накопичено загалом"
    M_MEASURED="Виміряно для цього слота"
    M_TYP_PEAK="типовий пік"
    M_DRAIN="витрата"
    M_NORMAL="Норма для вашого телефона"
    M_ABOVE="Вище"
    M_LEANS="Smart схиляється до економії, нижче"
    M_ALLOWS="дозволяє трохи більше."
    M_NOTFIXED1="Це не фіксовані числа — це медіана ваших же"
    M_NOTFIXED2="12 слотів, тому телефон, який просто гарячіший, не карається."
    M_RIGHTNOW="Зараз"
    M_LEAN_BAT="схиляється до економії"
    M_LEAN_PERF="схиляється до продуктивності"
    M_LEAN_BAL="збалансовано"
    M_TOUCH_BOOST="плюс коротке підняття при дотику до екрана"
    M_WATCHING="Спостерігає зараз"
    M_APP="застосунок"
    M_IDLE="простій"
    M_LIGHT="легке навантаження"
    M_NORMAL_USE="звичайне навантаження"
    M_HEAVY="високе навантаження"
    M_GAMING="гра"
    M_REMEMBERS="Памʼятає теплову поведінку застосунків:"
    M_APPS=""
    M_PREDICT="Прогноз часу екрана"
    M_AT_RATE="за поточної витрати"
    M_NOTE_PARTIAL="Примітка: працює на неповних даних для цього слота"
    M_NOTE_NEIGHBOUR="Примітка: використовується сусідній слот"
    M_NOTE_NODATA="Примітка: історії ще немає — безпечні значення"
    M_DISCARDED="сесій відкинуто як ненадійні"
    M_THIS_HOUR="о цій годині зазвичай"
    M_WARM_HERE="тепло для цього телефона — Smart схиляється до економії"
    M_COOL_HERE="прохолодно для цього телефона — Smart дозволяє трохи більше"
    M_SES_LEARNED="сесій вивчено"
    M_DRAIN_NOW="витрата зараз"
    M_BANKED="накопичено — Smart не керує на цьому профілі"
    M_FOREGROUND="активний застосунок"
    M_DP0="ніч"
    M_DP1="ранній ранок"
    M_DP2="ранок"
    M_DP3="день"
    M_DP4="вечір"
    M_DP5="пізній вечір"
    M_WEEKEND="вихідний"; M_WEEKDAY="будній день" ;;
  *de-*|*de_*|de)
    M_CONF_LOW="Noch niedrig - Smart nutzt hier vorwiegend sichere Standardwerte."
    M_CONF_HIGH="Hoch - Entscheidungen in diesem Fenster beruhen auf Messungen, nicht auf Standardwerten."
    M_DRAIN_NOSAMPLE="Verbrauch nicht gemessen - der Bildschirm ist hier nur kurz an"
    M_AWAKE="wach im Standby"; M_MIN="Min"
    M_AWAKE_BAD="!! das Gerät schläft nicht ein - teurer als jede Einstellung hier"
    M_SLOT="Zeitfenster"
    M_SLOT_OF="von 12"
    M_SLOT_H1="Ihr Tag ist in 12 Fenster geteilt, jedes wird separat gelernt -"
    M_SLOT_H2="an einem Werktagmorgen verhält sich ein Handy anders als am Sonntagabend."
    M_CONF="Sicherheit in diesem Fenster"
    M_SES_BANK="Sitzungen insgesamt gesammelt"
    M_MEASURED="Gemessen für dieses Fenster"
    M_TYP_PEAK="typische Spitze"
    M_DRAIN="Verbrauch"
    M_NORMAL="Normal für Ihr Gerät"
    M_ABOVE="Über"
    M_LEANS="neigt Smart zum Akku, unter"
    M_ALLOWS="erlaubt es etwas mehr."
    M_NOTFIXED1="Das sind keine festen Werte - es ist der Median Ihrer eigenen"
    M_NOTFIXED2="12 Fenster, damit ein von Natur aus wärmeres Gerät nicht bestraft wird."
    M_RIGHTNOW="Jetzt"
    M_LEAN_BAT="neigt zum Akku"
    M_LEAN_PERF="neigt zur Leistung"
    M_LEAN_BAL="ausgewogen"
    M_TOUCH_BOOST="plus kurzer Schub bei Bildschirmberührung"
    M_WATCHING="Beobachtet gerade"
    M_APP="App"
    M_IDLE="Leerlauf"
    M_LIGHT="leichte Nutzung"
    M_NORMAL_USE="normale Nutzung"
    M_HEAVY="starke Nutzung"
    M_GAMING="Spiel"
    M_REMEMBERS="Kennt das Wärmeverhalten von Apps:"
    M_APPS=""
    M_PREDICT="Geschätzte Bildschirmzeit"
    M_AT_RATE="bei aktuellem Verbrauch"
    M_NOTE_PARTIAL="Hinweis: unvollständige Daten für dieses Fenster"
    M_NOTE_NEIGHBOUR="Hinweis: Rückgriff auf ein Nachbarfenster"
    M_NOTE_NODATA="Hinweis: noch keine Historie - sichere Standardwerte"
    M_DISCARDED="Sitzung(en) als unzuverlässig verworfen"
    M_THIS_HOUR="zu dieser Stunde üblicherweise"
    M_WARM_HERE="warm für dieses Gerät - Smart neigt hier zum Akku"
    M_COOL_HERE="kühl für dieses Gerät - Smart erlaubt hier etwas mehr"
    M_SES_LEARNED="Sitzungen gelernt"
    M_DRAIN_NOW="Verbrauch jetzt"
    M_BANKED="gesammelt - Smart steuert in diesem Profil nicht"
    M_FOREGROUND="Vordergrund"
    M_DP0="Nacht"
    M_DP1="früher Morgen"
    M_DP2="Morgen"
    M_DP3="Mittag"
    M_DP4="Nachmittag"
    M_DP5="Abend"
    M_WEEKEND="Wochenende"; M_WEEKDAY="Wochentag" ;;
  *es-*|*es_*|es)
    M_CONF_LOW="Aún baja: Smart usa aquí sobre todo valores seguros."
    M_CONF_HIGH="Alta: las decisiones en esta franja se basan en lo medido, no en valores por defecto."
    M_DRAIN_NOSAMPLE="consumo no medido - aquí la pantalla se enciende poco tiempo"
    M_AWAKE="despierto en reposo"; M_MIN="min"
    M_AWAKE_BAD="!! el teléfono no entra en suspensión - cuesta más que cualquier ajuste de aquí"
    M_SLOT="Franja horaria"
    M_SLOT_OF="de 12"
    M_SLOT_H1="Tu día se divide en 12 franjas, cada una aprendida por separado:"
    M_SLOT_H2="un teléfono se comporta distinto un martes por la mañana que un domingo por la tarde."
    M_CONF="Confianza en esta franja"
    M_SES_BANK="sesiones acumuladas en total"
    M_MEASURED="Medido para esta franja"
    M_TYP_PEAK="pico típico"
    M_DRAIN="consumo"
    M_NORMAL="Normal para tu teléfono"
    M_ABOVE="Por encima de"
    M_LEANS="Smart tiende a batería, por debajo de"
    M_ALLOWS="permite un poco más."
    M_NOTFIXED1="No son valores fijos: son la mediana de tus propias"
    M_NOTFIXED2="12 franjas, así un teléfono que simplemente calienta más no es penalizado."
    M_RIGHTNOW="Ahora"
    M_LEAN_BAT="tiende a batería"
    M_LEAN_PERF="tiende a rendimiento"
    M_LEAN_BAL="equilibrado"
    M_TOUCH_BOOST="más un impulso breve al tocar la pantalla"
    M_WATCHING="Observando ahora"
    M_APP="app"
    M_IDLE="inactivo"
    M_LIGHT="uso ligero"
    M_NORMAL_USE="uso normal"
    M_HEAVY="uso intenso"
    M_GAMING="juego"
    M_REMEMBERS="Recuerda el comportamiento térmico de apps:"
    M_APPS=""
    M_PREDICT="Tiempo de pantalla estimado"
    M_AT_RATE="al ritmo actual"
    M_NOTE_PARTIAL="Nota: datos parciales para esta franja"
    M_NOTE_NEIGHBOUR="Nota: usando una franja vecina"
    M_NOTE_NODATA="Nota: sin historial aún - valores seguros"
    M_DISCARDED="sesión(es) descartadas por poco fiables"
    M_THIS_HOUR="a esta hora normalmente"
    M_WARM_HERE="cálido para este teléfono - Smart tiende a batería aquí"
    M_COOL_HERE="fresco para este teléfono - Smart permite un poco más aquí"
    M_SES_LEARNED="sesiones aprendidas"
    M_DRAIN_NOW="consumo ahora"
    M_BANKED="acumulado - Smart no dirige en este perfil"
    M_FOREGROUND="primer plano"
    M_DP0="noche"
    M_DP1="madrugada"
    M_DP2="mañana"
    M_DP3="mediodía"
    M_DP4="tarde"
    M_DP5="noche"
    M_WEEKEND="fin de semana"; M_WEEKDAY="día laborable" ;;
  *pt-*|*pt_*|pt)
    M_CONF_LOW="Ainda baixa: o Smart usa aqui sobretudo valores seguros."
    M_CONF_HIGH="Alta: as decisões nesta faixa baseiam-se no que foi medido, não em padrões."
    M_DRAIN_NOSAMPLE="consumo não medido - aqui a tela fica ligada pouco tempo"
    M_AWAKE="acordado em repouso"; M_MIN="min"
    M_AWAKE_BAD="!! o telefone não suspende - custa mais que qualquer ajuste daqui"
    M_SLOT="Faixa horária"
    M_SLOT_OF="de 12"
    M_SLOT_H1="Seu dia é dividido em 12 faixas, cada uma aprendida separadamente:"
    M_SLOT_H2="um telefone se comporta diferente numa manhã de semana e num domingo à noite."
    M_CONF="Confiança nesta faixa"
    M_SES_BANK="sessões acumuladas"
    M_MEASURED="Medido para esta faixa"
    M_TYP_PEAK="pico típico"
    M_DRAIN="consumo"
    M_NORMAL="Normal para seu telefone"
    M_ABOVE="Acima de"
    M_LEANS="Smart tende à bateria, abaixo de"
    M_ALLOWS="permite um pouco mais."
    M_NOTFIXED1="Não são valores fixos - são a mediana das suas próprias"
    M_NOTFIXED2="12 faixas, então um telefone naturalmente mais quente não é penalizado."
    M_RIGHTNOW="Agora"
    M_LEAN_BAT="tende à bateria"
    M_LEAN_PERF="tende ao desempenho"
    M_LEAN_BAL="equilibrado"
    M_TOUCH_BOOST="mais um impulso curto ao tocar a tela"
    M_WATCHING="Observando agora"
    M_APP="app"
    M_IDLE="ocioso"
    M_LIGHT="uso leve"
    M_NORMAL_USE="uso normal"
    M_HEAVY="uso pesado"
    M_GAMING="jogo"
    M_REMEMBERS="Lembra o comportamento térmico de apps:"
    M_APPS=""
    M_PREDICT="Tempo de tela estimado"
    M_AT_RATE="no ritmo atual"
    M_NOTE_PARTIAL="Nota: dados parciais para esta faixa"
    M_NOTE_NEIGHBOUR="Nota: usando uma faixa vizinha"
    M_NOTE_NODATA="Nota: sem histórico ainda - valores seguros"
    M_DISCARDED="sessão(ões) descartadas como não confiáveis"
    M_THIS_HOUR="nesta hora normalmente"
    M_WARM_HERE="quente para este telefone - Smart tende à bateria aqui"
    M_COOL_HERE="fresco para este telefone - Smart permite um pouco mais aqui"
    M_SES_LEARNED="sessões aprendidas"
    M_DRAIN_NOW="consumo agora"
    M_BANKED="acumulado - Smart não dirige neste perfil"
    M_FOREGROUND="primeiro plano"
    M_DP0="noite"
    M_DP1="madrugada"
    M_DP2="manhã"
    M_DP3="meio-dia"
    M_DP4="tarde"
    M_DP5="noite"
    M_WEEKEND="fim de semana"; M_WEEKDAY="dia útil" ;;
  *tr-*|*tr_*|tr)
    M_CONF_LOW="Henüz düşük - Smart burada çoğunlukla güvenli varsayılanları kullanıyor."
    M_CONF_HIGH="Yüksek - bu dilimdeki kararlar varsayılanlara değil ölçümlere dayanıyor."
    M_DRAIN_NOSAMPLE="tüketim ölçülmedi - burada ekran kısa süre açık kalıyor"
    M_AWAKE="beklemede uyanık"; M_MIN="dk"
    M_AWAKE_BAD="!! telefon uykuya geçmiyor - buradaki her ayardan pahalıya mal oluyor"
    M_SLOT="Zaman dilimi"
    M_SLOT_OF="/ 12"
    M_SLOT_H1="Gününüz 12 dilime bölünür, her biri ayrı öğrenilir -"
    M_SLOT_H2="telefon hafta içi sabah ile pazar akşamı farklı davranır."
    M_CONF="Bu dilimdeki güven"
    M_SES_BANK="toplam oturum biriktirildi"
    M_MEASURED="Bu dilim için ölçülen"
    M_TYP_PEAK="tipik tepe"
    M_DRAIN="tüketim"
    M_NORMAL="Telefonunuz için normal"
    M_ABOVE="Üstünde"
    M_LEANS="Smart pile yönelir, altında"
    M_ALLOWS="biraz daha izin verir."
    M_NOTFIXED1="Bunlar sabit sayılar değil - kendi 12 diliminizin"
    M_NOTFIXED2="medyanı, böylece doğası gereği daha sıcak bir telefon cezalandırılmaz."
    M_RIGHTNOW="Şu anda"
    M_LEAN_BAT="pile yöneliyor"
    M_LEAN_PERF="performansa yöneliyor"
    M_LEAN_BAL="dengeli"
    M_TOUCH_BOOST="artı ekrana dokunduğunuzda kısa bir hızlanma"
    M_WATCHING="Şu an izleniyor"
    M_APP="uygulama"
    M_IDLE="boşta"
    M_LIGHT="hafif kullanım"
    M_NORMAL_USE="normal kullanım"
    M_HEAVY="yoğun kullanım"
    M_GAMING="oyun"
    M_REMEMBERS="Uygulamaların ısı davranışını hatırlıyor:"
    M_APPS=""
    M_PREDICT="Tahmini ekran süresi"
    M_AT_RATE="mevcut hızda"
    M_NOTE_PARTIAL="Not: bu dilim için kısmi veri"
    M_NOTE_NEIGHBOUR="Not: komşu dilime geri dönülüyor"
    M_NOTE_NODATA="Not: henüz geçmiş yok - güvenli değerler"
    M_DISCARDED="oturum güvenilmez olarak atıldı"
    M_THIS_HOUR="bu saatte genellikle"
    M_WARM_HERE="bu telefon için sıcak - Smart burada pile yönelir"
    M_COOL_HERE="bu telefon için serin - Smart burada biraz daha izin verir"
    M_SES_LEARNED="oturum öğrenildi"
    M_DRAIN_NOW="şu anki tüketim"
    M_BANKED="biriktirildi - Smart bu profilde yönetmiyor"
    M_FOREGROUND="ön planda"
    M_DP0="gece"
    M_DP1="sabaha karşı"
    M_DP2="sabah"
    M_DP3="öğle"
    M_DP4="öğleden sonra"
    M_DP5="akşam"
    M_WEEKEND="hafta sonu"; M_WEEKDAY="hafta içi" ;;
  *fr-*|*fr_*|fr)
    M_CONF_LOW="Encore faible : Smart utilise ici surtout des valeurs sûres."
    M_CONF_HIGH="Élevée : les décisions dans ce créneau reposent sur les mesures, pas sur les valeurs par défaut."
    M_DRAIN_NOSAMPLE="consommation non mesurée - l’écran reste peu allumé ici"
    M_AWAKE="éveillé en veille"; M_MIN="min"
    M_AWAKE_BAD="!! le téléphone ne se met pas en veille - cela coûte plus que tout réglage ici"
    M_SLOT="Créneau horaire"
    M_SLOT_OF="sur 12"
    M_SLOT_H1="Votre journée est découpée en 12 créneaux, appris séparément —"
    M_SLOT_H2="un téléphone ne se comporte pas pareil un mardi matin et un dimanche soir."
    M_CONF="Confiance dans ce créneau"
    M_SES_BANK="sessions accumulées au total"
    M_MEASURED="Mesuré pour ce créneau"
    M_TYP_PEAK="pic habituel"
    M_DRAIN="consommation"
    M_NORMAL="Normal pour votre téléphone"
    M_ABOVE="Au-dessus de"
    M_LEANS="Smart penche vers la batterie, en dessous de"
    M_ALLOWS="il autorise un peu plus."
    M_NOTFIXED1="Ce ne sont pas des valeurs fixes : c’est la médiane de vos propres"
    M_NOTFIXED2="12 créneaux, pour qu’un téléphone naturellement plus chaud ne soit pas pénalisé."
    M_RIGHTNOW="Maintenant"
    M_LEAN_BAT="penche vers la batterie"
    M_LEAN_PERF="penche vers les performances"
    M_LEAN_BAL="équilibré"
    M_TOUCH_BOOST="plus une brève accélération quand vous touchez l’écran"
    M_WATCHING="Observe en ce moment"
    M_APP="appli"
    M_IDLE="inactif"
    M_LIGHT="usage léger"
    M_NORMAL_USE="usage normal"
    M_HEAVY="usage intensif"
    M_GAMING="jeu"
    M_REMEMBERS="Connaît le comportement thermique de"
    M_APPS="appli(s) vues"
    M_PREDICT="Temps d’écran estimé"
    M_AT_RATE="au rythme actuel"
    M_NOTE_PARTIAL="Note : données partielles pour ce créneau"
    M_NOTE_NEIGHBOUR="Note : repli sur un créneau voisin"
    M_NOTE_NODATA="Note : pas encore d’historique — valeurs sûres"
    M_DISCARDED="session(s) écartées comme peu fiables"
    M_THIS_HOUR="à cette heure, habituellement"
    M_WARM_HERE="chaud pour ce téléphone — Smart penche ici vers la batterie"
    M_COOL_HERE="frais pour ce téléphone — Smart autorise ici un peu plus"
    M_SES_LEARNED="sessions apprises"
    M_DRAIN_NOW="consommation actuelle"
    M_BANKED="accumulé — Smart ne pilote pas sur ce profil"
    M_FOREGROUND="premier plan"
    M_DP0="nuit"
    M_DP1="petit matin"
    M_DP2="matin"
    M_DP3="midi"
    M_DP4="après-midi"
    M_DP5="soir"
    M_WEEKEND="week-end"; M_WEEKDAY="jour de semaine" ;;
  *hy-*|*hy_*|hy)
    M_CONF_LOW="Դեռ ցածր է — Smart-ն այստեղ հիմնականում օգտագործում է անվտանգ արժեքներ։"
    M_CONF_HIGH="Բարձր է — այս հատվածի որոշումները հիմնված են չափումների, ոչ թե լռելյայն արժեքների վրա։"
    M_DRAIN_NOSAMPLE="ծախսը չի չափվել — էկրանն այստեղ կարճ է միանում"
    M_AWAKE="արթուն քնի ժամանակ"; M_MIN="րոպե"
    M_AWAKE_BAD="!! հեռախոսը չի քնում — սա ավելի թանկ է, քան ցանկացած կարգավորում այստեղ"
    M_SLOT="Ժամային հատված"
    M_SLOT_OF="12-ից"
    M_SLOT_H1="Օրը բաժանված է 12 հատվածի, յուրաքանչյուրը սովորվում է առանձին —"
    M_SLOT_H2="հեռախոսը աշխատանքային օրվա առավոտյան և կիրակի երեկոյան իրեն այլ կերպ է պահում։"
    M_CONF="Վստահությունն այս հատվածում"
    M_SES_BANK="սեսիա ընդհանուր կուտակված"
    M_MEASURED="Չափված այս հատվածի համար"
    M_TYP_PEAK="սովորական գագաթ"
    M_DRAIN="ծախս"
    M_NORMAL="Նորմալ ձեր հեռախոսի համար"
    M_ABOVE="Բարձր"
    M_LEANS="Smart-ը թեքվում է դեպի մարտկոց, ցածր"
    M_ALLOWS="թույլ է տալիս մի փոքր ավելին։"
    M_NOTFIXED1="Սրանք ֆիքսված թվեր չեն — դա ձեր իսկ 12 հատվածների"
    M_NOTFIXED2="միջինն է, որպեսզի բնականից տաք հեռախոսը չպատժվի։"
    M_RIGHTNOW="Հիմա"
    M_LEAN_BAT="թեքվում է դեպի մարտկոց"
    M_LEAN_PERF="թեքվում է դեպի արտադրողականություն"
    M_LEAN_BAL="հավասարակշռված"
    M_TOUCH_BOOST="գումարած կարճ արագացում էկրանին հպվելիս"
    M_WATCHING="Հիմա հետևում է"
    M_APP="հավելված"
    M_IDLE="պարապ"
    M_LIGHT="թեթև ծանրաբեռնվածություն"
    M_NORMAL_USE="սովորական ծանրաբեռնվածություն"
    M_HEAVY="բարձր ծանրաբեռնվածություն"
    M_GAMING="խաղ"
    M_REMEMBERS="Հիշում է հավելվածների ջերմային վարքը՝"
    M_APPS=""
    M_PREDICT="Էկրանի կանխատեսվող ժամանակ"
    M_AT_RATE="ընթացիկ ծախսի դեպքում"
    M_NOTE_PARTIAL="Նշում. այս հատվածի համար տվյալները թերի են"
    M_NOTE_NEIGHBOUR="Նշում. օգտագործվում է հարևան հատվածը"
    M_NOTE_NODATA="Նշում. պատմություն դեռ չկա — անվտանգ արժեքներ"
    M_DISCARDED="սեսիա մերժվել է որպես անվստահելի"
    M_THIS_HOUR="այս ժամին սովորաբար"
    M_WARM_HERE="տաք է այս հեռախոսի համար — Smart-ը թեքվում է դեպի մարտկոց"
    M_COOL_HERE="զով է այս հեռախոսի համար — Smart-ը թույլ է տալիս մի փոքր ավելին"
    M_SES_LEARNED="սեսիա սովորված"
    M_DRAIN_NOW="ծախսը հիմա"
    M_BANKED="կուտակված — Smart-ը այս պրոֆիլում չի կառավարում"
    M_FOREGROUND="ակտիվ հավելված"
    M_DP0="գիշեր"
    M_DP1="վաղ առավոտ"
    M_DP2="առավոտ"
    M_DP3="կեսօր"
    M_DP4="ցերեկ"
    M_DP5="երեկո"
    M_WEEKEND="հանգստյան օր"; M_WEEKDAY="աշխատանքային օր" ;;
  *it-*|*it_*|it)
    M_CONF_LOW="Ancora bassa: qui Smart usa soprattutto valori sicuri."
    M_CONF_HIGH="Alta: le decisioni in questa fascia si basano su ciò che ha misurato, non sui valori predefiniti."
    M_DRAIN_NOSAMPLE="consumo non misurato - qui lo schermo resta acceso poco"
    M_AWAKE="sveglio in standby"; M_MIN="min"
    M_AWAKE_BAD="!! il telefono non va in sospensione - costa più di qualsiasi impostazione qui"
    M_SLOT="Fascia oraria"
    M_SLOT_OF="di 12"
    M_SLOT_H1="La giornata è divisa in 12 fasce, ognuna appresa separatamente:"
    M_SLOT_H2="un telefono si comporta diversamente un martedì mattina e una domenica sera."
    M_CONF="Affidabilità in questa fascia"
    M_SES_BANK="sessioni accumulate in totale"
    M_MEASURED="Misurato per questa fascia"
    M_TYP_PEAK="picco tipico"
    M_DRAIN="consumo"
    M_NORMAL="Normale per il tuo telefono"
    M_ABOVE="Sopra"
    M_LEANS="Smart tende alla batteria, sotto"
    M_ALLOWS="concede un po\u2019 di più."
    M_NOTFIXED1="Non sono valori fissi: sono la mediana delle tue"
    M_NOTFIXED2="12 fasce, così un telefono naturalmente più caldo non viene penalizzato."
    M_RIGHTNOW="Adesso"
    M_LEAN_BAT="tende alla batteria"
    M_LEAN_PERF="tende alle prestazioni"
    M_LEAN_BAL="bilanciato"
    M_TOUCH_BOOST="più una breve spinta quando tocchi lo schermo"
    M_WATCHING="Sta osservando"
    M_APP="app"
    M_IDLE="inattivo"
    M_LIGHT="uso leggero"
    M_NORMAL_USE="uso normale"
    M_HEAVY="uso intenso"
    M_GAMING="gioco"
    M_REMEMBERS="Ricorda il comportamento termico delle app:"
    M_APPS=""
    M_PREDICT="Tempo schermo stimato"
    M_AT_RATE="al ritmo attuale"
    M_NOTE_PARTIAL="Nota: dati parziali per questa fascia"
    M_NOTE_NEIGHBOUR="Nota: si usa una fascia vicina"
    M_NOTE_NODATA="Nota: nessuno storico - valori sicuri"
    M_DISCARDED="sessioni scartate perché inaffidabili"
    M_THIS_HOUR="a quest\u2019ora di solito"
    M_WARM_HERE="caldo per questo telefono - Smart tende alla batteria qui"
    M_COOL_HERE="fresco per questo telefono - Smart concede un po\u2019 di più qui"
    M_SES_LEARNED="sessioni apprese"
    M_DRAIN_NOW="consumo ora"
    M_BANKED="accumulato - Smart non guida in questo profilo"
    M_FOREGROUND="in primo piano"
    M_DP0="notte"
    M_DP1="mattino presto"
    M_DP2="mattina"
    M_DP3="mezzogiorno"
    M_DP4="pomeriggio"
    M_DP5="sera"
    M_WEEKEND="fine settimana"; M_WEEKDAY="giorno feriale" ;;
  *ar-*|*ar_*|ar)
    M_CONF_LOW="لا تزال منخفضة — يستخدم Smart هنا القيم الآمنة غالبًا."
    M_CONF_HIGH="عالية — القرارات في هذه الفترة مبنية على ما قِيس، لا على القيم الافتراضية."
    M_DRAIN_NOSAMPLE="الاستهلاك لم يُقَس — الشاشة هنا تعمل لفترات قصيرة"
    M_AWAKE="مستيقظ أثناء النوم"; M_MIN="دقيقة"
    M_AWAKE_BAD="!! الهاتف لا يدخل السبات — هذا أغلى من أي إعداد هنا"
    M_SLOT="الفترة الزمنية"
    M_SLOT_OF="من 12"
    M_SLOT_H1="يومك مقسّم إلى 12 فترة، كل واحدة تُتعلَّم على حدة —"
    M_SLOT_H2="الهاتف يتصرف صباح يوم عمل بشكل مختلف عن مساء الأحد."
    M_CONF="الثقة في هذه الفترة"
    M_SES_BANK="جلسة مُجمّعة إجمالاً"
    M_MEASURED="المُقاس لهذه الفترة"
    M_TYP_PEAK="الذروة المعتادة"
    M_DRAIN="الاستهلاك"
    M_NORMAL="المعتاد لهاتفك"
    M_ABOVE="فوق"
    M_LEANS="يميل Smart إلى البطارية، وتحت"
    M_ALLOWS="يسمح بقليل إضافي."
    M_NOTFIXED1="هذه ليست أرقامًا ثابتة — إنها وسيط فتراتك"
    M_NOTFIXED2="الاثنتي عشرة، فالهاتف الأسخن بطبيعته لا يُعاقَب."
    M_RIGHTNOW="الآن"
    M_LEAN_BAT="يميل إلى البطارية"
    M_LEAN_PERF="يميل إلى الأداء"
    M_LEAN_BAL="متوازن"
    M_TOUCH_BOOST="بالإضافة إلى دفعة قصيرة عند لمس الشاشة"
    M_WATCHING="يراقب الآن"
    M_APP="التطبيق"
    M_IDLE="خامل"
    M_LIGHT="استخدام خفيف"
    M_NORMAL_USE="استخدام عادي"
    M_HEAVY="استخدام مكثف"
    M_GAMING="لعبة"
    M_REMEMBERS="يتذكر السلوك الحراري للتطبيقات:"
    M_APPS=""
    M_PREDICT="وقت الشاشة المتوقع"
    M_AT_RATE="بالمعدل الحالي"
    M_NOTE_PARTIAL="ملاحظة: بيانات جزئية لهذه الفترة"
    M_NOTE_NEIGHBOUR="ملاحظة: يُستخدم فترة مجاورة"
    M_NOTE_NODATA="ملاحظة: لا يوجد سجل بعد — قيم آمنة"
    M_DISCARDED="جلسة استُبعدت لعدم موثوقيتها"
    M_THIS_HOUR="في هذه الساعة عادةً"
    M_WARM_HERE="دافئ لهذا الهاتف — يميل Smart إلى البطارية هنا"
    M_COOL_HERE="بارد لهذا الهاتف — يسمح Smart بقليل إضافي هنا"
    M_SES_LEARNED="جلسة تم تعلمها"
    M_DRAIN_NOW="الاستهلاك الآن"
    M_BANKED="مُجمَّع — Smart لا يتحكم في هذا الملف"
    M_FOREGROUND="التطبيق النشط"
    M_DP0="ليل"
    M_DP1="فجر"
    M_DP2="صباح"
    M_DP3="ظهر"
    M_DP4="بعد الظهر"
    M_DP5="مساء"
    M_WEEKEND="عطلة"; M_WEEKDAY="يوم عمل" ;;
  zh-cn*|zh_cn*|*zh-hans*|zh)
    M_CONF_LOW="仍然较低 —— Smart 在这里主要使用安全默认值。"
    M_CONF_HIGH="较高 —— 这个时段的决策依据实测数据，而非默认值。"
    M_DRAIN_NOSAMPLE="未测量耗电 —— 这个时段屏幕只会短暂点亮"
    M_AWAKE="休眠时唤醒占比"; M_MIN="分钟"
    M_AWAKE_BAD="!! 手机没有真正休眠 —— 这比这里任何设置都更耗电"
    M_SLOT="时段"
    M_SLOT_OF="/ 12"
    M_SLOT_H1="一天分为 12 个时段，每段单独学习 ——"
    M_SLOT_H2="手机在工作日早晨和周日晚上的表现并不相同。"
    M_CONF="该时段的置信度"
    M_SES_BANK="已累计会话"
    M_MEASURED="该时段的实测值"
    M_TYP_PEAK="典型峰值"
    M_DRAIN="耗电"
    M_NORMAL="你的手机正常范围"
    M_ABOVE="高于"
    M_LEANS="Smart 偏向省电，低于"
    M_ALLOWS="则放宽一些。"
    M_NOTFIXED1="这些不是固定数值，而是你自己 12 个时段的"
    M_NOTFIXED2="中位数，因此天生偏热的手机不会被惩罚。"
    M_RIGHTNOW="当前"
    M_LEAN_BAT="偏向省电"
    M_LEAN_PERF="偏向性能"
    M_LEAN_BAL="平衡"
    M_TOUCH_BOOST="触摸屏幕时还有短暂提速"
    M_WATCHING="正在观察"
    M_APP="应用"
    M_IDLE="空闲"
    M_LIGHT="轻度使用"
    M_NORMAL_USE="一般使用"
    M_HEAVY="重度使用"
    M_GAMING="游戏"
    M_REMEMBERS="已记住这些应用的发热特性："
    M_APPS=""
    M_PREDICT="预计亮屏时间"
    M_AT_RATE="按当前速度"
    M_NOTE_PARTIAL="注意：该时段数据不完整"
    M_NOTE_NEIGHBOUR="注意：改用相邻时段"
    M_NOTE_NODATA="注意：暂无历史 —— 使用安全默认值"
    M_DISCARDED="个会话因不可靠被丢弃"
    M_THIS_HOUR="这个时间通常"
    M_WARM_HERE="对这台手机偏热 —— Smart 在此偏向省电"
    M_COOL_HERE="对这台手机偏凉 —— Smart 在此放宽一些"
    M_SES_LEARNED="已学习会话"
    M_DRAIN_NOW="当前耗电"
    M_BANKED="已累计 —— Smart 在此配置下不参与调度"
    M_FOREGROUND="前台应用"
    M_DP0="夜间"
    M_DP1="清晨"
    M_DP2="上午"
    M_DP3="中午"
    M_DP4="下午"
    M_DP5="晚上"
    M_WEEKEND="周末"; M_WEEKDAY="工作日" ;;
  *)
    M_CONF_LOW="Still low - Smart is mostly using safe defaults here."
    M_CONF_HIGH="High - decisions here are driven by what it measured, not defaults."
    M_DRAIN_NOSAMPLE="drain not measured - the screen is only on briefly here"
    M_AWAKE="awake while asleep"; M_MIN="min"
    M_AWAKE_BAD="!! the phone is not suspending - this costs more than any setting here"
    M_SLOT="Time slot"; M_SLOT_OF="of 12"
    M_SLOT_H1="Your day is split into 12 slots, each learned separately -"
    M_SLOT_H2="a phone behaves differently on a weekday morning than on a Sunday evening."
    M_CONF="Confidence in this slot"; M_SES_BANK="sessions banked overall"
    M_MEASURED="Measured for this slot"; M_TYP_PEAK="typical peak"; M_DRAIN="drain"
    M_NORMAL="Normal for your phone"
    M_ABOVE="Above"; M_LEANS="Smart leans to battery, below"; M_ALLOWS="it allows a little more."
    M_NOTFIXED1="These are not fixed numbers - they are the median of your own"
    M_NOTFIXED2="12 slots, so a phone that simply runs hotter is not punished for it."
    M_RIGHTNOW="Right now"; M_LEAN_BAT="leaning to battery"
    M_LEAN_PERF="leaning to performance"; M_LEAN_BAL="balanced"
    M_TOUCH_BOOST="plus a short boost when you touch the screen"
    M_WATCHING="Watching now"; M_APP="app"
    M_IDLE="idle"; M_LIGHT="light use"; M_NORMAL_USE="normal use"
    M_HEAVY="heavy use"; M_GAMING="gaming"
    M_REMEMBERS="Remembers the heat behaviour of"; M_APPS="app(s) it has seen"
    M_PREDICT="Predicted screen time left"; M_AT_RATE="at the current rate"
    M_NOTE_PARTIAL="Note: running on partial data for this slot"
    M_NOTE_NEIGHBOUR="Note: falling back to a neighbouring slot"
    M_NOTE_NODATA="Note: no usable history yet - safe defaults in use"
    M_DISCARDED="session(s) were discarded as unreliable"
    M_THIS_HOUR="this hour usually"
    M_WARM_HERE="warm for this phone - Smart leans to battery here"
    M_COOL_HERE="cool for this phone - Smart allows a little more here"
    M_SES_LEARNED="sessions learned"; M_DRAIN_NOW="drain now"
    M_BANKED="banked - Smart not steering on this profile"
    M_DP0="night"; M_DP1="early morning"; M_DP2="morning"; M_DP3="midday"; M_DP4="afternoon"; M_DP5="evening"
    M_WEEKEND="weekend"; M_WEEKDAY="weekday"
    M_FOREGROUND="foreground" ;;
esac

PROFILE="$(cat "$MODDIR/current_profile" 2>/dev/null || echo balanced)"

_lvl=$(dumpsys battery 2>/dev/null | grep -m1 ' level:' | awk '{print $2}')
_btemp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
_cap_uah=$(cat /sys/class/power_supply/battery/charge_full 2>/dev/null)

_cputemp=0
for z in /sys/class/thermal/thermal_zone*/; do
  tp=$(cat "${z}type" 2>/dev/null)
  case "$tp" in
    cpu-1-1-0|cpu0-silver-usr|cpuss-2-usr|cpu-0-0-0)
      tv=$(cat "${z}temp" 2>/dev/null)
      [ -n "$tv" ] && [ "$tv" -gt 1000 ] 2>/dev/null && _cputemp=$((tv / 1000)) && break
      ;;
  esac
done
if [ "$_cputemp" -eq 0 ]; then
  for z in /sys/class/thermal/thermal_zone*/; do
    tp=$(cat "${z}type" 2>/dev/null)
    case "$tp" in
      *cpu*)
        tv=$(cat "${z}temp" 2>/dev/null)
        if [ -n "$tv" ] && [ "$tv" -gt 1000 ] 2>/dev/null; then
          dc=$((tv / 1000))
          [ "$dc" -gt "$_cputemp" ] && _cputemp=$dc
        fi
        ;;
    esac
  done
fi

if [ -n "$_btemp" ] && [ "$_btemp" -gt 0 ] 2>/dev/null; then
  _btempC=$((_btemp / 10))
  _btempCx=$((_btemp % 10))
else
  _btempC=0
  _btempCx=0
fi

# Same source as the WebUI, in the same order of preference.
#
# This read smart_drain_ewma_x10 while the WebUI reads smart_drain_pctph_x10 and only falls
# back to the ewma. Two different rates, both labelled "measured", both feeding the same
# formula - so the two screens showed 6h13m and 10h21m six seconds apart. Neither was
# wrong; they were answering with different inputs.
#
# pctph is the current session's rate, ewma is the smoothed one. The WebUI picks pctph
# first, so this does too - agreeing on a number matters more here than which of the two
# is the better estimate, because a user comparing screens cannot see the difference.
_ewma_x10=$(grep "^smart_drain_pctph_x10=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2)
case "$_ewma_x10" in ''|0|*[!0-9]*) _ewma_x10=""; esac
[ -n "$_ewma_x10" ] || _ewma_x10=$(grep "^smart_drain_ewma_x10=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2)
# The WebUI also discards the rate when the measurement window is short; matching that
# keeps "(measured)" honest on both screens rather than only on one.
_dwin=$(grep "^smart_drain_window_s=" /dev/.asb/state 2>/dev/null | head -1 | cut -d= -f2)
case "$_dwin" in ''|*[!0-9]*) _dwin=0 ;; esac
[ "$_dwin" -lt 600 ] 2>/dev/null && _ewma_x10=0
_on_ma=0
if [ -n "$_ewma_x10" ] && [ "$_ewma_x10" -gt 0 ] 2>/dev/null && \
   [ -n "$_cap_uah" ] && [ "$_cap_uah" -gt 0 ] 2>/dev/null; then
  _on_ma=$(( (_cap_uah / 1000) * _ewma_x10 / 1000 ))
  _eta_note="(measured)"
fi
if [ "$_on_ma" -lt 50 ] 2>/dev/null; then
  case "$PROFILE" in
    performance) _on_ma=650 ;;
    battery)     _on_ma=400 ;;
    *)           _on_ma=500 ;;
  esac
  _eta_note="(heuristic)"
fi
_off_ma=$(( _on_ma / 10 ))
[ "$_off_ma" -lt 40 ] && _off_ma=40
[ "$_off_ma" -gt 90 ] && _off_ma=90

_remain_mah=0
if [ -n "$_cap_uah" ] && [ "$_cap_uah" -gt 0 ] 2>/dev/null && [ -n "$_lvl" ]; then
  _remain_mah=$(( (_cap_uah / 1000) * _lvl / 100 ))
fi

_ton_h=0
_ton_m=0
_toff_h=0
_toff_m=0
if [ "$_remain_mah" -gt 0 ] 2>/dev/null && [ "$_on_ma" -gt 0 ] 2>/dev/null; then
  _ton_min=$(( _remain_mah * 60 / _on_ma ))
  _ton_h=$(( _ton_min / 60 ))
  _ton_m=$(( _ton_min % 60 ))
fi
if [ "$_remain_mah" -gt 0 ] 2>/dev/null && [ "$_off_ma" -gt 0 ] 2>/dev/null; then
  _toff_min=$(( _remain_mah * 60 / _off_ma ))
  _toff_h=$(( _toff_min / 60 ))
  _toff_m=$(( _toff_min % 60 ))
fi

_auto_bat=$(grep -oE '"auto_bat":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)
_qn_active=$(grep -oE '"qn_active":[01]' /dev/.asb/state 2>/dev/null | head -1 | cut -d: -f2)

_rec_count=0
_rec_disabled=0
_rec_reason=""
if [ -r /dev/.asb/recovery.json ]; then
  _rec_line=$(cat /dev/.asb/recovery.json 2>/dev/null)
  _rec_count=$(echo "$_rec_line" | sed -n 's/.*"recovery_count":\([0-9]*\).*/\1/p')
  _rec_disabled=$(echo "$_rec_line" | sed -n 's/.*"gov_disabled":\([0-9]*\).*/\1/p')
  _rec_reason=$(echo "$_rec_line" | sed -n 's/.*"last_recovery_reason":"\([^"]*\)".*/\1/p')
  case "$_rec_count" in ''|*[!0-9]*) _rec_count=0 ;; esac
  case "$_rec_disabled" in ''|*[!0-9]*) _rec_disabled=0 ;; esac
fi

# Smart Mode status
_smart_enabled=0
_smart_bucket=0
_smart_daypart=0
_smart_we=0
_smart_conf=0
_smart_alpha=500
_smart_fb=4
_smart_app=0
_smart_sleep=0
_smart_veto=0
if [ -r /data/adb/asb/smart_mode_enabled ]; then
  _smart_enabled=$(cat /data/adb/asb/smart_mode_enabled 2>/dev/null)
  case "$_smart_enabled" in ''|*[!0-9]*) _smart_enabled=0 ;; esac
fi
if [ "$_smart_enabled" = "1" ] && [ -r /dev/.asb/state ]; then
  _smart_bucket=$(grep -m1 '^smart_bucket_id=' /dev/.asb/state | cut -d= -f2)
  _smart_daypart=$(grep -m1 '^smart_daypart=' /dev/.asb/state | cut -d= -f2)
  _smart_we=$(grep -m1 '^smart_is_weekend=' /dev/.asb/state | cut -d= -f2)
  _smart_conf=$(grep -m1 '^smart_confidence=' /dev/.asb/state | cut -d= -f2)
  _smart_alpha=$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state | cut -d= -f2)
  _smart_fb=$(grep -m1 '^smart_fallback_level=' /dev/.asb/state | cut -d= -f2)
  _smart_app=$(grep -m1 '^smart_app_hint=' /dev/.asb/state | cut -d= -f2)
  _smart_sleep=$(grep -m1 '^smart_sleep_override=' /dev/.asb/state | cut -d= -f2)
  _smart_veto=$(grep -m1 '^smart_thermal_veto=' /dev/.asb/state | cut -d= -f2)
  for _v in _smart_bucket _smart_daypart _smart_we _smart_conf _smart_alpha _smart_fb _smart_app _smart_sleep _smart_veto; do
    eval _val="\$$_v"
    case "$_val" in ''|*[!0-9]*) eval "$_v=0" ;; esac
  done
fi
_daypart_name=""
case "$_smart_daypart" in
  0) _daypart_name="sleep" ;;
  1) _daypart_name="wake" ;;
  2) _daypart_name="morn" ;;
  3) _daypart_name="day" ;;
  4) _daypart_name="evening" ;;
  5) _daypart_name="late" ;;
esac
_we_name=""
[ "$_smart_we" = "1" ] && _we_name=" (weekend)" || _we_name=" (weekday)"

# Everything below is rendered in a PROPORTIONAL font dialog, not a terminal.
# Box frames and space-padded columns cannot line up there (an emoji is two cells wide but one
# character), which is why the old ╭──╮ frame came out ragged.
echo ""
echo "  🚀  AutoSystemBoost V64"
if [ "$_smart_enabled" = "1" ]; then
  _conf_pct=$((_smart_conf / 10))
  echo "  🤖  Smart · bucket ${_smart_bucket} · ${_daypart_name}${_we_name} · conf ${_conf_pct}%"
  # The profile still matters under Smart: it is the rail the learner moves within, so
  # "Smart" alone does not tell you what the caps are anchored to.
  echo "  🎛  Profile: ${PROFILE} (Smart picks caps within it)"
else
  echo "  🎛  Profile: ${PROFILE} (manual — Smart off)"
fi
_bias="$(grep -E '^[[:space:]]*smart_battery_bias=' "$MODDIR/config/governor.conf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' ')"
# Show the LIVE learning weight, the same number the WebUI shows as "battery-lean", so the two
# screens agree.
# smart_battery_bias is a different thing - it is the user's configured tilt, not the current
# runtime weight - so it was showing 60% while the WebUI showed the live 100%, and they looked
# like a bug.
_alpha_live="$(grep -m1 '^smart_alpha_battery=' /dev/.asb/state 2>/dev/null | cut -d= -f2)"
[ -n "$_alpha_live" ] && echo "  ⚖️  Battery lean: $((_alpha_live / 10))% (live)"
[ -n "$_bias" ] && [ "$_bias" != "0" ] && echo "  🔋  Battery tilt set to: $((_bias / 10))%"
# The throttling threshold is now user-settable, so it belongs where the profile is - reading a
# temperature elsewhere in the report and not knowing what it is compared against was the gap.
#
# They used to sit further down, after the throttling line already called _cfg - so
# the action screen printed "_cfg: not found" right under the battery tilt and the
# throttling temperature came out blank. A helper has to exist before its first use.
_cfg() {
  grep -E "^[[:space:]]*$1=" "$MODDIR/config/governor.conf" 2>/dev/null \
    | head -1 | sed 's/.*=//' | tr -d ' \r'
}
_feat() {
  grep -E "^$1=" "$MODDIR/features.conf" 2>/dev/null | tail -1 | sed 's/.*=//' | tr -d ' \r'
}

_ste="$(_cfg sustained_temp_enter)"
[ -n "$_ste" ] && [ "$_ste" != "65" ] && echo "  🌡️  Throttling temperature: ${_ste}°C (default 65)"
if [ "$_rec_disabled" = "1" ]; then
  echo "  ⚠️  SAFE MODE  : governor disabled (${_rec_reason:-recovery})"
elif [ "$_rec_count" -gt 0 ] 2>/dev/null; then
  echo "  ⚠️  Recovery  : ${_rec_count} restart(s) — ${_rec_reason:-unknown}"
fi
echo ""
_cpu_note=""
[ "${_cputemp:-0}" -ge 80 ] 2>/dev/null && _cpu_note="  🔥 hot"
if [ "$_btempC" -gt 0 ]; then
  echo "  🌡  ${_cputemp}°C CPU  ·  ${_btempC}.${_btempCx}°C battery${_cpu_note}"
else
  echo "  🌡  ${_cputemp}°C CPU${_cpu_note}"
fi
echo "  🔋  ${_lvl:-?}%"
[ "$_auto_bat" = "1" ] && echo "  🔻 Auto-battery active"
[ "$_qn_active" = "1" ] && echo "  🌙 Night-quiet active"

if [ "$_smart_enabled" = "1" ]; then
  _alpha_pct=$((_smart_alpha / 10))
  # bucket/daypart/confidence are already on the header line - only print the things
  # that are NOT always true, so the screen stays short and every line carries news.
  [ "$_alpha_pct" != "100" ] && echo "  ⚖️  Battery bias: ${_alpha_pct}%"
  if [ "$_smart_fb" != "0" ]; then
    _fb_name=""
    case "$_smart_fb" in
      1) _fb_name="daypart fallback" ;;
      2) _fb_name="class fallback" ;;
      3) _fb_name="global fallback" ;;
      4) _fb_name="cold start (safe default)" ;;
    esac
    echo "  ↩️  Learning: ${_fb_name}"
  fi
  [ "$_smart_sleep" = "1" ] && echo "  🌙  Night-safe override active"
  [ "$_smart_veto" = "1" ] && echo "  🔥  Thermal veto active"
fi
echo ""
echo "  ⏳  Time to 0% ${_eta_note}"
echo "       ~${_ton_h}h ${_ton_m}m screen on  ·  ~${_toff_h}h ${_toff_m}m idle"

# ── Live state ──────────────────────────────────────────────────────────────────
# Read from the config the daemon reads, not from whatever the WebUI last drew.

_a_prof="$(_cfg audio_profile)";  [ -n "$_a_prof" ] || _a_prof="stock"
_a_dac="$(_cfg audio_dac_hifi)"
_a_loud="$(_cfg media_loudness)"; [ -n "$_a_loud" ] || _a_loud="stock"
_a_dsp="$(_cfg dsp_loudness)";    [ -n "$_a_dsp" ]  || _a_dsp="off"
_a_bt="$(_cfg bt_absvol_mode)";   [ -n "$_a_bt" ]   || _a_bt="stock"
_c_lvl="$(_cfg CAMERA_LEVEL)";    [ -n "$_c_lvl" ]  || _c_lvl="0"
_blur="$(_cfg disable_blur)"
_cool="$(_cfg cool_gaming)"
_dsp_so=0
{ [ -f /vendor/lib64/soundfx/libasbdsp.so ] || [ -f /vendor/lib/soundfx/libasbdsp.so ]; } && _dsp_so=1
# Assigned inside the WIFI / CAMERA gates further down; seed them here so the
# verification block at the end cannot read them unset.
_cc_drv=""
_vb_n=0

# Every place an effects config can live on any of these devices, in one list so the AUDIO
# section and the NOT APPLIED check below can never disagree about where to look.
# Both names matter: the SKU dirs on SM8650 carry audio_effects.xml, NOT
# audio_effects_config.xml - the installer registered into exactly those two files and the
# checker, which globbed only the *_config name under sku_*, reported the effect as missing on
# a device where it was live.
_asb_effect_files() {
  for _d in /odm/etc /vendor/etc /vendor/odm/etc /system/etc \
            /vendor/etc/audio/sku_* /odm/etc/audio/sku_* \
            /vendor/etc/audio /odm/etc/audio /system/vendor/etc/audio; do
    for _n in audio_effects_config.xml audio_effects.xml; do
      [ -f "$_d/$_n" ] && echo "$_d/$_n"
    done
  done
}

_st() { grep -m1 "^$1=" /dev/.asb/state 2>/dev/null | cut -d= -f2; }

# Append "$2" to the accumulator "$1", inserting the separator only between real items.
_join() {
  [ -n "$2" ] || { printf '%s' "$1"; return; }
  if [ -n "$1" ]; then printf '%s  ·  %s' "$1" "$2"; else printf '%s' "$2"; fi
}

_g_state="$(_st state)"
_g_owner="$(_st cap_owner)"
_g_cpumax="$(_st cpu_max)"
_g_dwell="$(_st dwell_sec)"
_g_iq="$(_st iq)"
_g_thermal="$(_st thermal)"
_g_head="$(_st headroom_pct)"
if [ -n "$_g_state" ]; then
  echo ""
  echo "  ⚡  ${H_GOV}"
  # cap_owner is empty until the governor has taken ownership; saying "unknown" is
  # noise, so just omit it and let the state speak.
  _gl="$_g_state"
  case "$_g_owner" in ''|unknown|none) : ;; *) _gl="$(_join "$_gl" "caps by ${_g_owner}")" ;; esac
  echo "       ${_gl}"

  _gl=""
  [ "${_g_cpumax:-0}" -gt 0 ] 2>/dev/null && _gl="$(_join "$_gl" "CPU max ${_g_cpumax} MHz")"
  [ -n "$_g_dwell" ] && _gl="$(_join "$_gl" "dwell ${_g_dwell}s")"
  [ -n "$_gl" ] && echo "       ${_gl}"

  _gl=""
  [ -n "$_g_iq" ] && _gl="$(_join "$_gl" "environment iq ${_g_iq}")"
  [ -n "$_g_head" ] && _gl="$(_join "$_gl" "headroom ${_g_head}%")"
  [ "${_g_thermal:-0}" != "0" ] && _gl="$(_join "$_gl" "🔥 thermal ${_g_thermal}")"
  [ -n "$_gl" ] && echo "       ${_gl}"
fi

# Show the SAME learner numbers the WebUI shows, so the two screens agree.
_l_sess="$(_st smart_sessions_total)"
[ -n "$_l_sess" ] || _l_sess="$(_st hist_sessions)"   # fall back on older governors
_l_conf="$(_st smart_last_confidence)"
[ -n "$_l_conf" ] || _l_conf="$(_st smart_confidence)"   # fall back on older governors
_l_pkg="$(_st smart_pkg)"
# smart_drain_pctph_x10 first: the EWMA field reads 0 on this governor (confirmed on
# device - pctph said 114 while ewma said 0), so preferring the EWMA meant the drain line
# never printed at all. Keep the EWMA as a fallback for older governors that fill it.
_l_drain="$(_st smart_drain_pctph_x10)"
case "$_l_drain" in ''|0) _l_drain="$(_st smart_drain_ewma_x10)" ;; esac
# Not gated on Smart being active.
#
# smart_mode_enabled goes to 0 when the profile leaves Smart, and that took the whole LEARNING
# block with it - so a user who dropped to 20% and got auto-switched to Battery saw "unknown, 0
# sessions" on a governor that had ten sessions banked and knew it.
# The sessions are history, not a live feature: they do not stop existing because the current
# profile is not Smart, and they are what Smart will use again next time it runs.
if [ -n "${_l_sess}${_l_pkg}" ]; then
  echo ""
  echo "  🧠  ${H_LEARN}"
  _ll=""
  if [ -n "$_l_sess" ]; then
    [ "$_l_sess" = "1" ] && _ll="1 ${M_SES_LEARNED}" \
                         || _ll="${_l_sess} ${M_SES_LEARNED}"
  fi
  # Confidence tier, worded the same way the WebUI tiers it.
  if [ -n "$_l_conf" ] && [ "$_l_conf" -gt 0 ] 2>/dev/null; then
    if   [ "$_l_conf" -ge 650 ]; then _tier="strong"
    elif [ "$_l_conf" -ge 350 ]; then _tier="active"
    else _tier="learning"; fi
    _ll="$(_join "$_ll" "${_tier} $((_l_conf / 10))%")"
  fi
  # What the current bucket has learned, and therefore why Smart is leaning the way it
  # is. The alpha number alone told nobody anything.
  _bt="$(_st smart_bucket_temp_x10)"; _bd="$(_st smart_bucket_drain_x10)"
  if [ -n "$_bt" ] && [ "$_bt" -gt 0 ] 2>/dev/null; then
    # A literal degree sign: printf %b expands \n and friends but not \uXXXX, so the
    # escape came out as the four characters "u00b0" on screen.
    _bl="       ${M_THIS_HOUR}: $((_bt / 10)).$((_bt % 10))°C"
    [ -n "$_bd" ] && [ "$_bd" -gt 0 ] 2>/dev/null \
      && _bl="${_bl}  ·  $((_bd / 10)).$((_bd % 10))%/h"
    printf '%b\n' "$_bl"
    # Compare against this device's learned thresholds, not fixed degrees.
    _tw="$(_st smart_therm_warm_x10)"; _tc="$(_st smart_therm_cool_x10)"
    case "$_tw" in ''|*[!0-9]*) _tw=420 ;; esac
    case "$_tc" in ''|*[!0-9]*) _tc=380 ;; esac
    [ "$_bt" -gt "$_tw" ] 2>/dev/null && echo "       (${M_WARM_HERE})"
    [ "$_bt" -lt "$_tc" ] 2>/dev/null && echo "       (${M_COOL_HERE})"
  fi
  [ "$_smart_enabled" != "1" ] && _ll="$(_join "$_ll" "$M_BANKED")"
  [ -n "$_ll" ] && echo "       ${_ll}"
  if [ -n "$_l_drain" ] && [ "$_l_drain" -gt 0 ] 2>/dev/null; then
    echo "       ${M_DRAIN_NOW}: $((_l_drain / 10)).$((_l_drain % 10))%/h"
  fi
  [ -n "$_l_pkg" ] && echo "       ${M_FOREGROUND}: ${_l_pkg}"

  # Full picture, only while Smart is the profile actually steering.
  #
  # Everything below already existed as a number in /dev/.asb/state and was readable by
  # nobody: 46 smart_* fields, of which the report showed four. The learner is the part of
  # this module people are most sceptical about, and "trust me, it is learning" is not an
  # answer - so this says what it has measured, what it concluded, and what it is doing
  # about it, in the order someone would ask.
  if [ "$_smart_enabled" = "1" ]; then
    echo ""
    echo "  🎓  ${H_SMART}"

    # --- 1. when it thinks it is -----------------------------------------------------
    _bid="$(_st smart_bucket_id)"; _dp="$(_st smart_daypart)"; _we="$(_st smart_is_weekend)"
    case "$_dp" in
      0) _dpn="$M_DP0" ;; 1) _dpn="$M_DP1" ;; 2) _dpn="$M_DP2" ;;
      3) _dpn="$M_DP3" ;; 4) _dpn="$M_DP4" ;; 5) _dpn="$M_DP5" ;;
      *) _dpn="?" ;;
    esac
    [ "$_we" = "1" ] && _dayk="$M_WEEKEND" || _dayk="$M_WEEKDAY"
    # Displayed 1-based. The internal id starts at 0, and "0 of 12" reads like a count
    # that has not started rather than the first of twelve.
    _bid_h=$(( ${_bid:-0} + 1 ))
    echo "       ${M_SLOT}: ${_dpn} · ${_dayk} (${_bid_h} ${M_SLOT_OF})"
    echo "         ${M_SLOT_H1}"
    echo "         ${M_SLOT_H2}"

    # --- 2. how sure it is -----------------------------------------------------------
    _conf="$(_st smart_confidence)"; _ses="$(_st smart_sessions_total)"
    if [ -n "$_conf" ] && [ "$_conf" -gt 0 ] 2>/dev/null; then
      echo "       ${M_CONF}: $((_conf / 10))%  ·  ${_ses:-0} ${M_SES_BANK}"
      # These two were left in English inside an otherwise translated block - visible on a
      # Russian screenshot as one stray sentence among the rest.
      [ "$_conf" -lt 350 ] 2>/dev/null && echo "         ${M_CONF_LOW}"
      [ "$_conf" -ge 650 ] 2>/dev/null && echo "         ${M_CONF_HIGH}"
    fi

    # --- 3. what it measured ---------------------------------------------------------
    _bt2="$(_st smart_bucket_temp_x10)"; _bd2="$(_st smart_bucket_drain_x10)"
    _tw2="$(_st smart_therm_warm_x10)"; _tc2="$(_st smart_therm_cool_x10)"
    if [ -n "$_bt2" ] && [ "$_bt2" -gt 0 ] 2>/dev/null; then
      # Drain is only recorded from screen-on stretches of 10 minutes or more, so a bucket
      # a person only ever visits briefly - the night one, checking the time - learns a
      # temperature but never a drain rate. Printing "0.0%/h" there states a measurement
      # that was never taken, next to a temperature that was: the two numbers on that line
      # had different standing and looked identical.
      if [ "${_bd2:-0}" -gt 0 ] 2>/dev/null; then
        echo "       ${M_MEASURED}: $((_bt2 / 10)).$((_bt2 % 10))°C ${M_TYP_PEAK}, $((_bd2 / 10)).$((_bd2 % 10))%/h ${M_DRAIN}"
      else
        echo "       ${M_MEASURED}: $((_bt2 / 10)).$((_bt2 % 10))°C ${M_TYP_PEAK} (${M_DRAIN_NOSAMPLE})"
      fi
      if [ -n "$_tw2" ] && [ "$_tw2" -gt 0 ] 2>/dev/null; then
        # Say the band, then the edges. "warm above 56, cool below 48" listed two
        # thresholds and read as a single self-contradicting range - the normal zone
        # between them was never stated, so the two numbers looked like nonsense.
        echo "       ${M_NORMAL}: $((_tc2 / 10))-$((_tw2 / 10))°C"
        echo "         ${M_ABOVE} $((_tw2 / 10))°C ${M_LEANS} $((_tc2 / 10))°C ${M_ALLOWS}"
        echo "         ${M_NOTFIXED1}"
        echo "         ${M_NOTFIXED2}"
      fi
    fi

    # --- 4. what it decided ----------------------------------------------------------
    _alpha="$(_st smart_alpha_battery)"; _ib="$(_st smart_interactive_bonus)"
    if [ -n "$_alpha" ] && [ "$_alpha" -gt 0 ] 2>/dev/null; then
      if   [ "$_alpha" -ge 650 ] 2>/dev/null; then _lean="$M_LEAN_BAT"
      elif [ "$_alpha" -le 350 ] 2>/dev/null; then _lean="$M_LEAN_PERF"
      else _lean="$M_LEAN_BAL"; fi
      echo "       ${M_RIGHTNOW}: ${_lean} (${_alpha}/1000)"
      [ -n "$_ib" ] && [ "$_ib" -gt 0 ] 2>/dev/null \
        && echo "         ${M_TOUCH_BOOST} (+${_ib})"
    fi

    # --- 5. what it is watching in real time -----------------------------------------
    _wl=""
    _ah="$(_st smart_app_hint)"
    case "$_ah" in
      0) _ahn="$M_IDLE" ;; 1) _ahn="$M_LIGHT" ;; 2) _ahn="$M_NORMAL_USE" ;;
      3) _ahn="$M_HEAVY" ;; 4) _ahn="$M_GAMING" ;; *) _ahn="" ;;
    esac
    [ -n "$_ahn" ] && _wl="${M_APP}: ${_ahn}"
    _hot="$(_st smart_app_hot)"
    [ "$_hot" = "1" ] && _wl="$(_join "$_wl" "this app runs hot")"
    _veto="$(_st smart_thermal_veto)"
    [ "$_veto" = "1" ] && _wl="$(_join "$_wl" "thermal veto ACTIVE - holding back for heat")"
    _slp="$(_st smart_sleep_override)"
    [ "$_slp" = "1" ] && _wl="$(_join "$_wl" "sleep window - minimal activity")"
    _lowb="$(_st smart_lowbat_override)"
    [ "$_lowb" = "1" ] && _wl="$(_join "$_wl" "low battery - saving")"
    _chg="$(_st smart_charge_assist)"
    [ "$_chg" = "1" ] && _wl="$(_join "$_wl" "charging - extra headroom while cool")"
    [ -n "$_wl" ] && echo "       ${M_WATCHING}: ${_wl}"

    _aph="$(_st smart_appheat_n)"
    [ -n "$_aph" ] && [ "$_aph" -gt 0 ] 2>/dev/null \
      && echo "       ${M_REMEMBERS} ${_aph} ${M_APPS}"

    # --- 6. how long the battery is expected to last ---------------------------------
    _bp="$(_st smart_budget_pred_h_x10)"
    if [ -n "$_bp" ] && [ "$_bp" -gt 0 ] 2>/dev/null; then
      echo "       ${M_PREDICT}: $((_bp / 10)).$((_bp % 10))h ${M_AT_RATE}"
    fi

    # --- 7. honest limits ------------------------------------------------------------
    _fb="$(_st smart_fallback_level)"
    case "$_fb" in
      0) : ;;
      1) echo "       ${M_NOTE_PARTIAL}" ;;
      2) echo "       ${M_NOTE_NEIGHBOUR}" ;;
      3) echo "       ${M_NOTE_NODATA}" ;;
    esac
    _qf="$(_st smart_q_fail)"
    [ -n "$_qf" ] && [ "$_qf" -gt 0 ] 2>/dev/null \
      && echo "       ${_qf} ${M_DISCARDED}"
  fi
fi

echo ""
echo "  🎵  ${H_AUDIO}"
_audio_l="       ${_a_prof} profile"
[ "$_a_dac" = "1" ] && _audio_l="${_audio_l}  ·  hi-fi DAC"
echo "$_audio_l"
_loud_l="       loudness: ${_a_loud}"
[ "$_a_dsp" != "off" ] && _loud_l="${_loud_l}  ·  DSP +${_a_dsp} dB"
echo "$_loud_l"
[ "$_a_bt" = "disabled" ] && echo "       BT volume: phone drives gain (independent scales)"
# The compressor only exists while the DSP is on - saying "compressor: on" next to a
# disabled DSP describes a setting, not the device.
if [ "$_a_dsp" != "off" ]; then
  case "$(_cfg dsp_compressor)" in
    off|0|false) echo "       compressor: off  ·  limiter only" ;;
    *)           echo "       compressor: on  ·  6:1 above -24 dBFS" ;;
  esac
fi
_a_bass="$(_cfg dsp_bass)"
case "$_a_bass" in ''|off|0) : ;; *) echo "       bass shelf: +${_a_bass} dB @ 90 Hz" ;; esac
if [ "$_a_dsp" != "off" ]; then
  _l64="✗"; _l32="✗"
  [ -f /vendor/lib64/soundfx/libasbdsp.so ] && _l64="✓"
  [ -f /vendor/lib/soundfx/libasbdsp.so ] && _l32="✓"
  _dsp_abi="?"
  if [ -f /vendor/lib64/soundfx/libasbdsp.so ]; then
    if grep -aq 'ASB createEffect' /vendor/lib64/soundfx/libasbdsp.so 2>/dev/null; then
      _dsp_abi="AIDL"
    elif grep -aq 'AELI\|ASB_DSP' /vendor/lib64/soundfx/libasbdsp.so 2>/dev/null; then
      _dsp_abi="legacy"
    fi
  fi
  if [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" = "1" ] \
     && [ "$(getprop persist.asb.dsp.comp 2>/dev/null)" = "0" ]; then
    echo "       compressor: off (limiter only)"
  fi
  echo "       libasbdsp: 64-bit ${_l64}  ·  32-bit ${_l32}  ·  ABI ${_dsp_abi}"
  _dsp_registered=0
  for _ecs in $(_asb_effect_files); do
    if grep -q 'asb_loudness' "$_ecs" 2>/dev/null; then
      _dsp_registered=1
      echo "       effect registered in: ${_ecs}"
      break
    fi
  done
  _dsp_attacher="✗"
  pgrep -f '/data/adb/asb/asb_dsp_attach' >/dev/null 2>&1 && _dsp_attacher="✓"
  _dsp_live_mb="$(getprop persist.asb.dsp.gain_mb 2>/dev/null)"
  case "$_dsp_live_mb" in ''|*[!0-9]*) _dsp_live="?" ;; *) _dsp_live="$(( _dsp_live_mb / 100 ))" ;; esac
  _dsp_on="$(getprop persist.asb.dsp.enable 2>/dev/null)"
  [ "$_dsp_registered" = "1" ] && _dsp_reg_mark="✓" || _dsp_reg_mark="✗"
  echo "       DSP status: requested +${_a_dsp}dB · live +${_dsp_live}dB · enabled=${_dsp_on:-0} · attacher ${_dsp_attacher} · registered ${_dsp_reg_mark}"
fi

echo ""
echo "  📷  ${H_CAMERA}"
# OxygenOS variants may expose the effective retouch config under either /odm or /vendor/odm.
# Do not report a staged/secondary root as live merely because it is checked first: select the
# readable candidate with the largest app list and retain its path for an actionable verdict.
_vb_n=0; _vb_live=""
for _vb_try in /odm/etc/camera/config/video_beauty_default_config \
               /vendor/odm/etc/camera/config/video_beauty_default_config; do
  [ -r "$_vb_try" ] || continue
  _vb_try_n="$(grep -c '"packageName"' "$_vb_try" 2>/dev/null)"
  case "$_vb_try_n" in ''|*[!0-9]*) _vb_try_n=0 ;; esac
  if [ "$_vb_try_n" -gt "$_vb_n" ] 2>/dev/null; then
    _vb_n="$_vb_try_n"; _vb_live="$_vb_try"
  fi
done
_cam_l="processing level ${_c_lvl}"
[ "${_vb_n:-0}" -gt 0 ] 2>/dev/null && _cam_l="$(_join "$_cam_l" "${_vb_n} retouch apps")"
echo "       ${_cam_l}"
[ -n "$_vb_live" ] && echo "       retouch config: $_vb_live"
_cam_ag="$(_cfg CAMERA_AGGRESSIVE)"
_cam_in="$(_cfg CAMERA_AGGRESSIVE_INJECT)"
_cam_l=""
[ "$_cam_ag" = "1" ] && _cam_l="$(_join "$_cam_l" "aggressive tone")"
case "$_cam_in" in
  full) _cam_l="$(_join "$_cam_l" "inject: full")" ;;
  ''|standard) : ;;
  *) _cam_l="$(_join "$_cam_l" "inject: ${_cam_in}")" ;;
esac
[ -n "$_cam_l" ] && echo "       ${_cam_l}"
# The grade is a ratio applied to the device's own tuning file, so report what it
# multiplied rather than a bare level number - the level alone says nothing about what
# changed. Only lines that differ from stock are printed.
_c_grain="$(_cfg CAMERA_GRAIN)";    case "$_c_grain" in ''|3) _c_grain="" ;; esac
_c_contr="$(_cfg CAMERA_CONTRAST)"; case "$_c_contr" in ''|3) _c_contr="" ;; esac
_c_port="$(_cfg CAMERA_PORTRAIT)";  case "$_c_port"  in ''|0) _c_port=""  ;; esac
_c_low="$(_cfg CAMERA_LOWLIGHT)";   case "$_c_low"   in ''|0) _c_low=""   ;; esac
[ -n "$_c_grain" ] && echo "       film grain: ${_c_grain}/8 (3 = stock)"
[ -n "$_c_contr" ] && echo "       contrast & colour depth: ${_c_contr}/8 (3 = stock)"
[ -n "$_c_port" ]  && echo "       portrait AI: ${_c_port}/6 (ships off)"
# Camera hold belongs here, not under SYSTEM.
#
# It reports that the governor is holding interactive caps BECAUSE the camera pipeline is
# streaming - a camera fact that was printed three sections away from everything else about the
# camera.
# The block that printed it also carried a mangled `echo ""echo ""`, emitting a stray blank
# line, and it was gated on lpm_mode and the LPM category, which have nothing to do with the
# camera: on a device with LPM switched off, camera hold was never reported at all.
if [ "$(_st camera_hold)" = "1" ]; then
  echo "       hold ACTIVE · interactive caps held, cpuset + uclamp lifted"
fi
[ -n "$_c_low" ]   && echo "       macro / low-light sharpening: ${_c_low}/8"
# Whether the grade actually landed on the live partition, which is the only claim
# worth making - the config saying 4 proved nothing until this was checked.
_c_live="/odm/etc/camera/conf_tuning_params.json"
if [ "${_c_lvl:-0}" -gt 0 ] 2>/dev/null && [ -r "$_c_live" ]; then
  _c_bw="$(grep -m1 -o '"BlendWeight"[^]]*]' "$_c_live" 2>/dev/null | sed 's/.*\[//;s/\]//')"
  case "$_c_bw" in
    *0.35,*0.5,*0.7*) echo "       ⚠️  grade NOT on the live file (still stock values)" ;;
    ?*)               echo "       ✅ live file graded: BlendWeight [${_c_bw}]" ;;
  esac
fi


echo ""
echo "  💾  ${H_MEMORY}"
_bgl="$(_cfg BG_TRIM_LEVEL)"
_ml=""
[ -n "$_bgl" ] && _ml="$(_join "$_ml" "bg trim: level ${_bgl}")"
_swp="$(cat /proc/sys/vm/swappiness 2>/dev/null)"
[ -n "$_swp" ] && _ml="$(_join "$_ml" "swappiness ${_swp}")"
[ -n "$_ml" ] && echo "       ${_ml}"
_mfree="$(grep -m1 MemAvailable /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}')"
_zram="$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if(t>0) print int((t-f)/1024)}' /proc/meminfo 2>/dev/null)"
_ml=""
[ -n "$_mfree" ] && _ml="$(_join "$_ml" "${_mfree} MB free")"
[ -n "$_zram" ] && _ml="$(_join "$_ml" "zram ${_zram} MB used")"
[ -n "$_ml" ] && echo "       ${_ml}"

if [ "$(_feat NET)" = "1" ]; then
  echo ""
  echo "  🌐  ${H_NETWORK}"
  _nl=""
  _cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
  [ -n "$_cc" ] && _nl="$(_join "$_nl" "$_cc")"
  _qd="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
  [ -n "$_qd" ] && _nl="$(_join "$_nl" "$_qd")"
  _nb="$(cat /proc/sys/net/core/netdev_budget 2>/dev/null)"
  [ -n "$_nb" ] && _nl="$(_join "$_nl" "budget ${_nb}")"
  [ -n "$_nl" ] && echo "       TCP: ${_nl}"

# What the user ASKED for, alongside what the kernel is actually running.
#
# The lines above read the live sysctls - true, but not the whole story: a request the kernel
# refused looks identical to one that was never made.
_nv="/data/adb/asb/net_apply_result"
_nverd() { [ -f "$_nv" ] && grep -E "^$1=" "$_nv" 2>/dev/null | head -1 | sed 's/.*=//'; }
_nfmt() {
  _w="$(_cfg "$2")"
  case "$_w" in ''|auto) return 0 ;; esac
  _v="$(_nverd "$2")"
  case "$_v" in
    unavailable) echo "       $1: ${_w} requested · NOT SUPPORTED by this kernel" ;;
    failed)      echo "       $1: ${_w} requested · NOT APPLIED" ;;
    pending)     echo "       $1: ${_w} · waiting for a link" ;;
    *)           if [ -n "$3" ] && [ "$3" != "$_w" ]; then
                   echo "       $1: ${_w} requested · running ${3}"
                 else
                   echo "       $1: ${_w}"
                 fi ;;
  esac
}
_nfmt "ramp (other links)" net_congestion "$_cc"
_nfmt "queue (other links)" net_qdisc "$_qd"

# Per-link overrides print only when set, so the section stays short on a default install
# and grows only for someone who has actually split Wi-Fi from mobile.
for _pk in net_congestion_wifi net_congestion_mobile net_qdisc_wifi net_qdisc_mobile; do
  _pv="$(_cfg "$_pk")"
  case "$_pv" in ''|auto) continue ;; esac
  case "$_pk" in *_wifi) _plabel="Wi-Fi" ;; *) _plabel="mobile" ;; esac
  case "$_pk" in net_congestion_*) _pwhat="ramp" ;; *) _pwhat="queue" ;; esac
  case "$(_nverd "$_pk")" in
    unavailable) echo "       ${_pwhat} · ${_plabel}: ${_pv} · NOT SUPPORTED" ;;
    failed)      echo "       ${_pwhat} · ${_plabel}: ${_pv} · NOT APPLIED" ;;
    *)           echo "       ${_pwhat} · ${_plabel}: ${_pv}" ;;
  esac
done

# Initial windows: read the real route attributes, since that is the only proof the change
# survived the connectivity stack replacing the route underneath us.
_rt="$(_cfg net_route_tune)"
case "$_rt" in
  ''|off) : ;;
  *)
    _rtl="$(ip route show 2>/dev/null | grep -m1 -oE 'initcwnd [0-9]+ initrwnd [0-9]+')"
    if [ -n "$_rtl" ]; then
      echo "       buffers: ${_rt} · ${_rtl} on the default route"
    else
      echo "       buffers: ${_rt} · not on the route yet (pending or replaced)"
    fi
    ;;
esac

# Wi-Fi region and scan rate live here too - they are network settings, and putting them
# under a separate WIFI heading split one topic across two sections.
_wcc="$(_cfg wifi_country)"
case "$_wcc" in
  ''|auto) : ;;
  *) case "$(_nverd wifi_country)" in
       failed) echo "       Wi-Fi region: ${_wcc} · NOT APPLIED" ;;
       *)      echo "       Wi-Fi region: ${_wcc}" ;;
     esac ;;
esac
_wst="$(_cfg wifi_scan_throttle)"
case "$_wst" in
  0) echo "       Wi-Fi scan: unthrottled (roams sooner, costs battery)" ;;
  1) echo "       Wi-Fi scan: stock limit (4 per 2 min)" ;;
esac
_handover="$(_cfg net_handover_fast)"
case "$_handover" in
  1) echo "       Wi-Fi → mobile handover: fast (cellular context kept ready while awake)" ;;
  *) : ;;
esac
  # Which interface is actually carrying traffic - not always rmnet_data0.
  _if="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [a-z0-9_]+' | head -1 | cut -d' ' -f2)"
  if [ -n "$_if" ]; then
    _rx="$(cat "/sys/class/net/$_if/statistics/rx_bytes" 2>/dev/null)"
    _nl="route via ${_if}"
    [ -n "$_rx" ] && _nl="${_nl}  ·  $((_rx / 1048576)) MB rx"
    echo "       ${_nl}"
  fi
fi

  # Modem LPM: a NETWORK line, gated on LPM, with its own wording.
  #
  # Three things were wrong.
  if [ "$(_feat LPM)" = "1" ]; then
    _lpm="$(cat /dev/.asb/lpm_mode 2>/dev/null | cut -d'|' -f1)"
    case "$_lpm" in
      fast) echo "       modem LPM: fast · data call held up (low latency)" ;;
      save) echo "       modem LPM: save · radio idling, keepalives stretched" ;;
      '')   : ;;
      *)    echo "       modem LPM: normal · profile defaults" ;;
    esac
  fi

# Wi-Fi status is not conditional on camera hold.
#
# This block opened with `if camera_hold = 1` and never printed anything about the camera -
# it only wrapped the Wi-Fi section, so the report showed Wi-Fi exactly when the camera was
# streaming and hid it the rest of the time. Both halves are wrong: the information is
# absent when it is useful and present when it is irrelevant.
#
# camera_hold is still read - it is reported in its own line below, where it belongs.
_cam_hold="$(_st camera_hold)"

echo ""
  echo "  📶  ${H_WIFI}"
# Read what the DRIVER actually ended up with, not `settings get global wifi_country_code`.
# That settings key is telephony-derived and the framework keeps rewriting it from the SIM, so
# it reported the SIM's country (IT) while the module's override was live - which looked
# exactly like the tweak had failed.
_wifi_dump="$(dumpsys wifi 2>/dev/null)"
_cc_drv="$(echo "$_wifi_dump" | grep -iE 'mDriverCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
_cc_ovr="$(echo "$_wifi_dump" | grep -iE 'mOverrideCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
_cc_tel="$(echo "$_wifi_dump" | grep -iE 'mTelephonyCountryCode' | head -1 | grep -oE '[A-Z]{2}[[:space:]]*$' | tr -d ' ')"
[ -n "$_cc_drv" ] || _cc_drv="$(cmd -w wifi get-country-code 2>/dev/null | grep -oE '[A-Z]{2}' | head -1)"
_cc_forced=0
[ -f /data/adb/asb/wifi_cc_forced ] && _cc_forced=1
_cc_want=""
for _pf in /data/adb/modules/AutoSystemBoost/profiles/*.sh; do
  [ -f "$_pf" ] || continue
  case "$_pf" in *"/$(cat /data/adb/modules/AutoSystemBoost/current_profile 2>/dev/null).sh") ;; *) continue ;; esac
  _cc_want="$(grep -E '^[[:space:]]*WIFI_COUNTRY=' "$_pf" 2>/dev/null | head -1 | sed 's/.*=//' | tr -d ' \r"' | tr '[:lower:]' '[:upper:]')"
done

if [ -n "$_cc_drv" ]; then
  _wl="       region: ${_cc_drv}"
  [ "$_cc_forced" = "1" ] && _wl="${_wl} (forced)"
  [ -n "$_cc_tel" ] && [ "$_cc_tel" != "$_cc_drv" ] && _wl="${_wl}  ·  SIM says ${_cc_tel}"
  echo "$_wl"
elif [ "$_cc_forced" = "1" ]; then
  echo "       region: forced${_cc_ovr:+ ${_cc_ovr}} (radio off?)"
fi
  _txq="$(cat /sys/class/net/wlan0/tx_queue_len 2>/dev/null)"
  _lnk="$(echo "$_wifi_dump" | grep -m1 -iE 'mWifiInfo|SSID' | grep -oE '[0-9]+Mbps' | head -1)"
  _wl2=""
  [ -n "$_txq" ] && _wl2="$(_join "$_wl2" "txqueue ${_txq}")"
  [ -n "$_lnk" ] && _wl2="$(_join "$_wl2" "link ${_lnk}")"
  [ -n "$_wl2" ] && echo "       ${_wl2}"
# Camera hold, stated plainly instead of being used as an invisible gate.
[ "$_cam_hold" = "1" ] && echo "       camera hold active - interactive caps held for the capture pipeline"

if [ "$(_feat GPS)" = "1" ]; then
  echo ""
  echo "  🛰  ${H_GPS}"
  _agps="$(settings get global assisted_gps_enabled 2>/dev/null)"
  _gl=""
  case "$_agps" in 1) _gl="$(_join "$_gl" "A-GPS on")" ;; 0) _gl="$(_join "$_gl" "A-GPS off")" ;; esac
  _xtra="$(settings get global gps_xtra_server 2>/dev/null)"
  case "$_xtra" in *gpsonextra*) _gl="$(_join "$_gl" "XTRA servers set")" ;; esac
  [ -n "$_gl" ] && echo "       ${_gl}"
fi

echo ""
# If the fail-safe fired, say so first - a user whose blur setting silently stopped
# working deserves to know the module turned it off rather than that it broke.
if [ -f /data/adb/asb/prop_blocks_disabled ]; then
  echo ""
  echo "  ⚠️  BOOT SAFETY"
  echo "       ASB removed its display properties after two failed boots."
  echo "       Re-enable blur and animations one at a time to find the culprit."
fi
_pbn="$(cat /data/adb/asb/prop_boot_counter 2>/dev/null)"
case "$_pbn" in
  ''|0) : ;;
  *) echo "       (boot-safety counter at ${_pbn}/2 - last boot did not report completion)" ;;
esac

# Interface gets its own heading. Blur and animations were reported under SYSTEM next to
# process limits and logging, which put four unrelated things under one word - and the
# WebUI has had them as separate categories for a while now. The report should agree with
# the screen the user just came from.
echo "  🖥  ${H_IFACE}"
echo "       blur: $([ "$_blur" = "1" ] && echo off || echo stock)"
# Animations: auto follows blur, so resolve it rather than printing "auto" and leaving
# the reader to work out what that means on this device.
_ui_fx="$(_cfg ui_effects_level)"
case "$_ui_fx" in
  flat|0)  echo "       animations: simplified" ;;
  stock|1) echo "       animations: normal" ;;
  *)       [ "$_blur" = "1" ] \
             && echo "       animations: simplified (auto, follows blur)" \
             || echo "       animations: normal (auto, follows blur)" ;;
esac
case "$(_cfg UX_MANAGE_TIMEOUTS)" in
  1) echo "       UI speed: managed (animations and touch windows scaled per profile)" ;;
esac
case "$(_cfg lockscreen_shortcuts)" in
  clean) echo "       lock screen: camera and wallet shortcuts hidden" ;;
esac

# Sleep. Nothing reported this at all, which is a gap on the one subsystem whose whole
# purpose is what happens while nobody is looking - and the night window is learned, so
# the user cannot know it without being told.
echo ""
echo "  🌙  ${H_SLEEP}"
  # The suspend figure first: when it is bad, nothing else in this section matters.
  _aw="$(_st awake_pct_screenoff)"; _awm="$(_st awake_window_min)"
  if [ -n "$_aw" ] && [ "$_aw" -ge 0 ] 2>/dev/null; then
    echo "       ${M_AWAKE}: ${_aw}% (${_awm:-0} ${M_MIN})"
    [ "$_aw" -gt 15 ] 2>/dev/null && echo "       ${M_AWAKE_BAD}"
  fi
_dz="$(_cfg doze_level)"
case "$_dz" in
  night)
    _nw="/data/adb/asb/night_window.conf"
    if [ -r "$_nw" ]; then
      _nsm="$(grep -E '^sleep_min=' "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      _nwm="$(grep -E '^wake_min='  "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
      _nns="$(grep -E '^samples='   "$_nw" 2>/dev/null | head -1 | sed 's/.*=//')"
    fi
    case "$_nsm$_nwm" in
      ''|*[!0-9]*) echo "       deep sleep: night mode, still learning your schedule" ;;
      *)
        # Report the window actually used, margins included - printing the raw learned
        # times would not match when the phone changes behaviour.
        _ws=$(( (_nsm + 15) % 1440 )); _we=$(( (_nwm - 20 + 1440) % 1440 ))
        printf '       deep sleep: night mode · %02d:%02d-%02d:%02d (learned from %s nights)\n' \
          $((_ws / 60)) $((_ws % 60)) $((_we / 60)) $((_we % 60)) "${_nns:-?}" ;;
    esac
    [ -f /data/adb/asb/aod_baseline ] && echo "       always-on display: paused for the night window"
    ;;
  moderate)   echo "       deep sleep: moderate (idle after 5 min instead of 30)" ;;
  aggressive) echo "       deep sleep: aggressive (idle after 2 min; messages may lag)" ;;
  *)          echo "       deep sleep: stock" ;;
esac
case "$(_cfg night_quiet_enable)" in
  1) echo "       night quiet: sensor polling slowed inside the sleep window" ;;
esac

echo ""
echo "  ⚙️  ${H_SYSTEM}"
case "$(_cfg phantom_procs)" in
  relaxed) echo "       background processes: unlimited (phantom monitor off)" ;;
  strict)  echo "       background processes: Android default (32 max)" ;;
esac
case "$(_cfg UX_MANAGE_OEM_TOGGLES)" in
  1) echo "       OEM toggles: managed (RAM expansion, battery, heat)" ;;
esac

# Haptics. The numbers that matter are the OEM stepless values actually in force, not
# the level we asked for - a rejected write would leave the two disagreeing.
_hap="$(_cfg haptic_strength)"
_hap_t="$(_cfg haptic_touch_strength)"
case "$_hap" in
  ''|-1|auto|stock) echo "       vibration: stock (not managed)" ;;
  0|off)            echo "       vibration: off" ;;
  *)
    _hap_live="$(settings get system notification_stepless_vibration_intensity 2>/dev/null)"
    _hap_l="       vibration: ${_hap}/10"
    case "$_hap_live" in ''|null) : ;; *) _hap_l="${_hap_l}  ·  live ${_hap_live}" ;; esac
    case "$_hap_t" in
      ''|-1|auto) _hap_l="${_hap_l}  ·  touch: follows" ;;
      0)          _hap_l="${_hap_l}  ·  touch: off" ;;
      *)          _hap_l="${_hap_l}  ·  touch: ${_hap_t}/10" ;;
    esac
    echo "$_hap_l" ;;
esac

# Every category, not the six that happened to be hard-coded here. Wrapped by hand
# because a single 20-item line is unreadable on a phone.
_cats=""; _catn=0; _catline=""
for _c in CPU VM AUDIO BT NFC CAMERA MEDIA NET WIFI GPS KERNEL LOG LPM \
          RADIO_IMS DISPLAY FPS SECURITY BG_TRIM VENDOR_OVERLAY SOTER_REPAIR; do
  [ "$(_feat "$_c")" = "1" ] || continue
  _catline="$(_join "$_catline" "$_c")"
  _catn=$((_catn + 1))
  if [ "$_catn" -ge 5 ]; then
    echo "       ${_catline}"
    _catline=""; _catn=0
  fi
done
[ -n "$_catline" ] && echo "       ${_catline}"
# Magisk does its magic mounts in a private namespace, so /proc/mounts read from here shows
# zero entries for the module even when the overlay is perfectly live - on KernelSU the same
# grep finds them.
_mnt="$(grep -c 'AutoSystemBoost' /proc/mounts 2>/dev/null)"
case "$_mnt" in ''|*[!0-9]*) _mnt=0 ;; esac
_ovl_live=0
for _op in /vendor/lib64/soundfx/libasbdsp.so /vendor/lib/soundfx/libasbdsp.so; do
  [ -f "$_op" ] && { _ovl_live=1; break; }
done
_krn="$(uname -r 2>/dev/null | cut -d- -f1)"
if [ "$_mnt" -gt 0 ] 2>/dev/null; then
  _sysl="       overlay: ${_mnt} mount$([ "$_mnt" = "1" ] || echo s)"
elif [ "$_ovl_live" = "1" ]; then
  _sysl="       overlay: live (private namespace)"
else
  _sysl="       overlay: not detected"
fi
[ -n "$_krn" ] && _sysl="${_sysl}  ·  kernel ${_krn}"
_up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
if [ -n "$_up" ]; then
  _sysl="${_sysl}  ·  up $((_up / 3600))h $(((_up % 3600) / 60))m"
fi
echo "$_sysl"


_abo="$(cat /data/adb/asb/auto_battery_origin 2>/dev/null)"
if [ -n "$_abo" ]; then
  echo ""
  echo "  🔋  ${H_BATT}"
  echo "       switched here automatically · returns to ${_abo} when charged"
fi


# ── Configured vs actually applied ────────────────────────────────────────────── The sections
# above report what the config ASKS for.
# A setting that silently does nothing is invisible everywhere else - that is precisely how
# "DSP +9 dB" shipped for weeks next to a library that was never installed.
_bad=""
_add_bad() { _bad="${_bad}${_bad:+
}       $1"; }

# governor process
pgrep -f 'asb_governor|/asb$' >/dev/null 2>&1 || _add_bad "governor is not running"

# audio profile -> UHQA property
if [ "$_a_prof" = "hifi" ] && [ "$(getprop persist.audio.uhqa 2>/dev/null)" != "1" ]; then
  _add_bad "hi-fi profile — persist.audio.uhqa is not 1 (restart audioserver?)"
fi

# media loudness -> the reshape leaves a marker in the table it rewrote
if [ "$_a_loud" != "stock" ]; then
  grep -q 'ASB:VOLCURVE' /vendor/etc/default_volume_tables.xml 2>/dev/null \
    || _add_bad "loudness ${_a_loud} — volume table not reshaped (reboot needed?)"
fi

# DSP -> library staged AND registered; either half missing means silence
if [ "$_a_dsp" != "off" ]; then
  [ "$_dsp_so" = "1" ] || _add_bad "DSP +${_a_dsp} dB — libasbdsp.so not installed (reinstall)"
  # Two different failures hide behind "not registered", and they need different fixes: the
  # staged copy under /data/adb/asb/odm_patched is what install.sh patches, and a bind mount is
  # what makes it the live file.
  # Patched-but-not-bound means the mount was skipped (bootloop fuse, or the boot counter
  # tripped); not-patched-at-all means install never ran the registration.
  _reg_live=0; _reg_stage=0
  for _ec in $(_asb_effect_files); do
    grep -q 'asb_loudness' "$_ec" 2>/dev/null && { _reg_live=1; break; }
  done
  # Search the whole staged tree AND the module overlay.
  # The old two-path probe missed every device whose effects config lives under a per-SKU
  # directory (sku_cliffs, sku_pineapple, ...), so a registration that had actually landed was
  # still reported as "install never ran the registration" - the wrong fix for the user to be
  # told to apply.
  for _ec in $(find /data/adb/asb/odm_patched \
                    /data/adb/modules/AutoSystemBoost/system \
                    -type f -name 'audio_effects*.xml' 2>/dev/null); do
    grep -q 'asb_loudness' "$_ec" 2>/dev/null && { _reg_stage=1; break; }
  done
  if [ "$_reg_live" != "1" ]; then
    if [ "$_reg_stage" = "1" ]; then
      _add_bad "DSP +${_a_dsp} dB — effect registered but the odm bind is not mounted"
      [ -f /data/adb/asb/vendor_overlay_blocked ] \
        && _add_bad "  (overlay is blocked by the bootloop fuse — see uninstall/reinstall)"
    else
      _add_bad "DSP +${_a_dsp} dB — effect not registered by install (reinstall)"
    fi
  fi
  [ "$(getprop persist.asb.dsp.enable 2>/dev/null)" = "1" ] \
    || _add_bad "DSP +${_a_dsp} dB — persist.asb.dsp.enable is not 1"

fi

# blur -> report WHICH properties took, not just that something did not.
# If the persist ones land and the ro ones do not, the root manager's resetprop cannot touch
# read-only properties on this setup - which is a completely different problem from "the tweak
# did not run".
if [ "$_blur" = "1" ]; then
  # The real switch first. If persist.sys.sf.disable_blurs is 1, SurfaceFlinger has blur
  # off regardless of the capability/oplus keys, so that alone means applied.
  _b_sf="$(getprop persist.sys.sf.disable_blurs 2>/dev/null)"
  _b_ro_bad=0; _b_ro_n=0
  for _bp in ro.surface_flinger.supports_background_blur:0 \
             ro.surface_flinger.media_panel_bg_blur:0 \
             ro.oplus.display.disable.volume_blur:1 \
             ro.oplus.gaussianlevel:0 \
             ro.launcher.blur.appLaunch:0; do
    _bn="${_bp%:*}"; _bw="${_bp##*:}"
    _bv="$(getprop "$_bn" 2>/dev/null)"
    [ -n "$_bv" ] || continue
    _b_ro_n=$((_b_ro_n + 1))
    [ "$_bv" = "$_bw" ] || _b_ro_bad=$((_b_ro_bad + 1))
  done
  _b_ps_bad=0
  [ "$(getprop persist.sys.oplus.anim_level 2>/dev/null)" = "0" ] || _b_ps_bad=$((_b_ps_bad + 1))
  [ "$(getprop persist.sys.oplus.material_blur_switch 2>/dev/null)" = "false" ] || _b_ps_bad=$((_b_ps_bad + 1))

  # persist.sys.sf.disable_blurs is authoritative: if it is 1, blur is off at the
  # SurfaceFlinger level and we are done, whatever the capability keys say.
  if [ "$_b_sf" = "1" ]; then
    :   # applied
  else
    _sp_has=0
    for _spf in /data/adb/modules/AutoSystemBoost/system.prop "$MODDIR/system.prop"; do
      grep -q '^persist.sys.sf.disable_blurs=1' "$_spf" 2>/dev/null && { _sp_has=1; break; }
    done
    if [ "$_sp_has" = "1" ]; then
      _add_bad "blur — set in system.prop (persist.sys.sf.disable_blurs), applies after a reboot"
    else
      _add_bad "blur — persist.sys.sf.disable_blurs not set (${_b_ro_bad}/${_b_ro_n} legacy keys also off)"
    fi
  fi
fi

# wi-fi -> driver domain.
# The check below used to assert a hardcoded "CR", so on every device that has ever had a SIM
# in it this line was guaranteed to fire - a permanent false alarm sitting in NOT APPLIED next
# to two real findings.
if [ "$(_feat WIFI)" = "1" ] && [ -n "$_cc_drv" ] && [ -n "$_cc_want" ] \
   && [ "$_cc_drv" != "$_cc_want" ]; then
  _add_bad "Wi-Fi ${_cc_want} — driver is on ${_cc_drv} (override did not take)"
fi

# camera -> the retouch list is the visible half of the camera patch
if [ "$(_feat CAMERA)" = "1" ] && [ "${_c_lvl:-0}" -gt 0 ] 2>/dev/null; then
  [ "${_vb_n:-0}" -ge 7 ] 2>/dev/null \
    || _add_bad "camera — retouch app list not injected (${_vb_n:-0} apps; ${_vb_live:-no live config})"
fi

echo ""
if [ -n "$_bad" ]; then
  echo "  ⚠️  NOT APPLIED"
  echo "$_bad"
else
  echo "  ✅  All configured tweaks verified applied"
fi

# The link, not the launch.
#
# This used to open Telegram every time the report finished. A diagnostic command should
# not take over the screen when someone is reading its output - and a person running it to
# investigate a problem is the least likely to want an app switch at that moment. The
# address is printed instead, and the WebUI already has a button for those who want it.
echo ""
echo "  ─────────────────────────────"
echo "  💬  t.me/AutoSystemBoost"
echo ""

exit 0
