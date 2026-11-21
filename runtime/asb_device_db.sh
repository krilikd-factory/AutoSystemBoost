#!/system/bin/sh
asb_db_model() {
  _dbn=""; _dbc=""; _dbf=""
  _dbm="$(printf '%s' "$1" | tr 'a-z' 'A-Z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_dbm" in
    "ONE A0001"|"ONE A1001") _dbn="OnePlus One"; _dbc="bacon"; _dbf=phone ;;
    "ONE A2001"|"ONE A2003"|"ONE A2005") _dbn="OnePlus 2"; _dbc="oneplus2"; _dbf=phone ;;
    "ONE E1000"|"ONE E1001"|"ONE E1003"|"ONE E1005") _dbn="OnePlus X"; _dbc="onyx"; _dbf=phone ;;
    "ONEPLUS A3000"|"ONEPLUS A3003") _dbn="OnePlus 3"; _dbc="oneplus3"; _dbf=phone ;;
    "ONEPLUS A3010"|"ONEPLUS A3013") _dbn="OnePlus 3T"; _dbc="oneplus3t"; _dbf=phone ;;
    "ONEPLUS A5000") _dbn="OnePlus 5"; _dbc="cheeseburger"; _dbf=phone ;;
    "ONEPLUS A5010") _dbn="OnePlus 5T"; _dbc="dumpling"; _dbf=phone ;;
    "ONEPLUS A6000"|"ONEPLUS A6003") _dbn="OnePlus 6"; _dbc="enchilada"; _dbf=phone ;;
    "ONEPLUS A6010"|"ONEPLUS A6013") _dbn="OnePlus 6T"; _dbc="fajita"; _dbf=phone ;;
    "GM1900"|"GM1901"|"GM1903"|"GM1905") _dbn="OnePlus 7"; _dbc="guacamoleb"; _dbf=phone ;;
    "GM1910"|"GM1911"|"GM1913"|"GM1915") _dbn="OnePlus 7 Pro"; _dbc="guacamole"; _dbf=phone ;;
    "GM1917") _dbn="OnePlus 7 Pro"; _dbc="guacamolet"; _dbf=phone ;;
    "GM1920") _dbn="OnePlus 7 Pro 5G"; _dbc="guacamoleg"; _dbf=phone ;;
    "GM1925") _dbn="OnePlus 7 Pro 5G"; _dbc="guacamoles"; _dbf=phone ;;
    "HD1900"|"HD1901"|"HD1903"|"HD1905") _dbn="OnePlus 7T"; _dbc="hotdogb"; _dbf=phone ;;
    "HD1907") _dbn="OnePlus 7T"; _dbc="hotdogt"; _dbf=phone ;;
    "HD1910"|"HD1911"|"HD1913") _dbn="OnePlus 7T Pro"; _dbc="hotdog"; _dbf=phone ;;
    "HD1925") _dbn="OnePlus 7T Pro 5G"; _dbc="hotdogg"; _dbf=phone ;;
    "IN2010"|"IN2011"|"IN2013"|"IN2015") _dbn="OnePlus 8"; _dbc="instantnoodle"; _dbf=phone ;;
    "IN2017") _dbn="OnePlus 8"; _dbc="instantnoodlet"; _dbf=phone ;;
    "IN2019") _dbn="OnePlus 8"; _dbc="instantnoodlevis"; _dbf=phone ;;
    "IN2020"|"IN2021"|"IN2023"|"IN2025") _dbn="OnePlus 8 Pro"; _dbc="instantnoodlep"; _dbf=phone ;;
    "KB2000"|"KB2001"|"KB2003"|"KB2005") _dbn="OnePlus 8T"; _dbc="kebab"; _dbf=phone ;;
    "KB2007") _dbn="OnePlus 8T+"; _dbc="kebabt"; _dbf=phone ;;
    "LE2100"|"LE2101") _dbn="OnePlus 9R"; _dbc="lemonades"; _dbf=phone ;;
    "LE2110"|"LE2111"|"LE2113"|"LE2115") _dbn="OnePlus 9"; _dbc="lemonade"; _dbf=phone ;;
    "LE2117") _dbn="OnePlus 9"; _dbc="lemonadet"; _dbf=phone ;;
    "LE2119") _dbn="OnePlus 9"; _dbc="lemonadev"; _dbf=phone ;;
    "LE2120"|"LE2121"|"LE2123"|"LE2125") _dbn="OnePlus 9 Pro"; _dbc="lemonadep"; _dbf=phone ;;
    "LE2127") _dbn="OnePlus 9 Pro"; _dbc="lemonadept"; _dbf=phone ;;
    "MT2110"|"MT2111") _dbn="OnePlus 9RT"; _dbc="martini"; _dbf=phone ;;
    "NE2210"|"NE2211"|"NE2213"|"NE2215"|"NE2217") _dbn="OnePlus 10 Pro"; _dbc="negroni"; _dbf=phone ;;
    "PGKM10") _dbn="OnePlus Ace"; _dbc="pickle"; _dbf=phone ;;
    "CPH2423"|"CPH2411") _dbn="OnePlus 10R"; _dbc="pickle"; _dbf=phone ;;
    "PGZ110") _dbn="OnePlus Ace Race"; _dbc="qqcandy"; _dbf=phone ;;
    "PGP110") _dbn="OnePlus Ace Pro"; _dbc="ovaltine"; _dbf=phone ;;
    "CPH2413"|"CPH2415"|"CPH2417"|"CPH2419") _dbn="OnePlus 10T"; _dbc="ovaltine"; _dbf=phone ;;
    "PHB110"|"CPH2447"|"CPH2449"|"CPH2451") _dbn="OnePlus 11"; _dbc="salami"; _dbf=phone ;;
    "PHK110") _dbn="OnePlus Ace 2"; _dbc="udon"; _dbf=phone ;;
    "CPH2487") _dbn="OnePlus 11R"; _dbc="udon"; _dbf=phone ;;
    "PHP110") _dbn="OnePlus Ace 2V"; _dbc="vitamin"; _dbf=phone ;;
    "CPH2491"|"CPH2493") _dbn="OnePlus Nord 3"; _dbc="vitamin"; _dbf=phone ;;
    "PJA110") _dbn="OnePlus Ace 2 Pro"; _dbc="xigua"; _dbf=phone ;;
    "PJD110"|"CPH2573"|"CPH2581"|"CPH2583") _dbn="OnePlus 12"; _dbc="waffle"; _dbf=phone ;;
    "PJE110") _dbn="OnePlus Ace 3"; _dbc="aston"; _dbf=phone ;;
    "CPH2585"|"CPH2609"|"CPH2611") _dbn="OnePlus 12R"; _dbc="aston"; _dbf=phone ;;
    "PJF110") _dbn="OnePlus Ace 3V"; _dbc="audi"; _dbf=phone ;;
    "PJX110") _dbn="OnePlus Ace 3 Pro"; _dbc="corvette"; _dbf=phone ;;
    "PJZ110"|"CPH2649"|"CPH2653"|"CPH2655") _dbn="OnePlus 13"; _dbc="dodge"; _dbf=phone ;;
    "PKG110") _dbn="OnePlus Ace 5"; _dbc="giulia"; _dbf=phone ;;
    "CPH2645"|"CPH2647"|"CPH2691") _dbn="OnePlus 13R"; _dbc="giulia"; _dbf=phone ;;
    "PKR110") _dbn="OnePlus Ace 5 Pro"; _dbc="hummer"; _dbf=phone ;;
    "PLC110") _dbn="OnePlus Ace 5 Ultra"; _dbc="emira"; _dbf=phone ;;
    "PLF110") _dbn="OnePlus Ace 5 Race"; _dbc="subaru"; _dbf=phone ;;
    "PKX110") _dbn="OnePlus 13T"; _dbc="pagani"; _dbf=phone ;;
    "CPH2723") _dbn="OnePlus 13s"; _dbc="pagani"; _dbf=phone ;;
    "PLK110"|"CPH2745"|"CPH2747"|"CPH2749") _dbn="OnePlus 15"; _dbc="infiniti"; _dbf=phone ;;
    "PLQ110") _dbn="OnePlus Ace 6"; _dbc="ktm"; _dbf=phone ;;
    "PLR110") _dbn="OnePlus Ace 6T"; _dbc="macan"; _dbf=phone ;;
    "CPH2767"|"CPH2769"|"CPH2771") _dbn="OnePlus 15R"; _dbc="macan"; _dbf=phone ;;
    "PLZ110") _dbn="OnePlus 15T"; _dbc="fairlady"; _dbf=phone ;;
    "PMB110") _dbn="OnePlus Ace 6 Ultra"; _dbc="roadster"; _dbf=phone ;;
    "PLU110") _dbn="OnePlus Turbo 6"; _dbc="volkswagen"; _dbf=phone ;;
    "CPH2793"|"CPH2795") _dbn="OnePlus Nord 6"; _dbc="volkswagen"; _dbf=phone ;;
    "PLY110") _dbn="OnePlus Turbo 6V"; _dbc="prado"; _dbf=phone ;;
    "CPH2805"|"CPH2807") _dbn="OnePlus Nord CE 6"; _dbc="prado"; _dbf=phone ;;
    "PYS110") _dbn="OnePlus Turbo 6X"; _dbc="kof"; _dbf=phone ;;
    "PYR110") _dbn="OnePlus Turbo 6X Pro"; _dbc="lol"; _dbf=phone ;;
    "PYB110") _dbn="OnePlus 16"; _dbc="pokemon"; _dbf=phone ;;
    "PYF110") _dbn="OnePlus Ace 7"; _dbc="mario"; _dbf=phone ;;
    "PMS110") _dbn="OnePlus Ace 7 Pro"; _dbc="redalert"; _dbf=phone ;;
    "AC2001"|"AC2003") _dbn="OnePlus Nord"; _dbc="avicii"; _dbf=phone ;;
    "DN2101"|"DN2103") _dbn="OnePlus Nord 2"; _dbc="denniz"; _dbf=phone ;;
    "CPH2399"|"CPH2401") _dbn="OnePlus Nord 2T"; _dbc="karen"; _dbf=phone ;;
    "CPH2661"|"CPH2663") _dbn="OnePlus Nord 4"; _dbc="avalon"; _dbf=phone ;;
    "CPH2707"|"CPH2709") _dbn="OnePlus Nord 5"; _dbc="lexus"; _dbf=phone ;;
    "EB2101"|"EB2103") _dbn="OnePlus Nord CE"; _dbc="ebba"; _dbf=phone ;;
    "IV2201") _dbn="OnePlus Nord CE 2"; _dbc="ivan"; _dbf=phone ;;
    "CPH2381"|"CPH2409") _dbn="OnePlus Nord CE 2 Lite"; _dbc="oscar"; _dbf=phone ;;
    "CPH2569") _dbn="OnePlus Nord CE 3"; _dbc="ziti"; _dbf=phone ;;
    "CPH2465"|"CPH2467") _dbn="OnePlus Nord CE 3 Lite"; _dbc="larry"; _dbf=phone ;;
    "CPH2513"|"CPH2515") _dbn="OnePlus Nord N30"; _dbc="larry"; _dbf=phone ;;
    "CPH2613") _dbn="OnePlus Nord CE 4"; _dbc="benz"; _dbf=phone ;;
    "CPH2619"|"CPH2621") _dbn="OnePlus Nord CE 4 Lite"; _dbc="camry"; _dbf=phone ;;
    "CPH2717"|"CPH2719") _dbn="OnePlus Nord CE 5"; _dbc="honda"; _dbf=phone ;;
    "CPH2943") _dbn="OnePlus Nord CE 6 Lite"; _dbc="suzuki-o"; _dbf=phone ;;
    "CPH2955") _dbn="OnePlus N6"; _dbc="mumbai-o"; _dbf=phone ;;
    "CPH2971") _dbn="OnePlus N6x"; _dbc="mumbai-c5"; _dbf=phone ;;
    "CPH2993") _dbn="OnePlus N6 Lite"; _dbc=""; _dbf=phone ;;
    "BE2025"|"BE2026"|"BE2029") _dbn="OnePlus Nord N10"; _dbc="billie8"; _dbf=phone ;;
    "BE2028") _dbn="OnePlus Nord N10"; _dbc="billie8t"; _dbf=phone ;;
    "BE2011"|"BE2012"|"BE2013"|"BE2015") _dbn="OnePlus Nord N100"; _dbc="bengal"; _dbf=phone ;;
    "GN2200"|"CPH2459") _dbn="OnePlus Nord N20"; _dbc="gunnar"; _dbf=phone ;;
    "CPH2469") _dbn="OnePlus Nord N20 SE"; _dbc="zhaoyun-o"; _dbf=phone ;;
    "CPH2605") _dbn="OnePlus Nord N30 SE"; _dbc="fanli-o"; _dbf=phone ;;
    "DE2117") _dbn="OnePlus Nord N200"; _dbc="dre9"; _dbf=phone ;;
    "DE2118") _dbn="OnePlus Nord N200"; _dbc="dre8t"; _dbf=phone ;;
    "CPH2389") _dbn="OnePlus Nord N300"; _dbc="hilda"; _dbf=phone ;;
    "CPH2551") _dbn="OnePlus Open"; _dbc="hedwig"; _dbf=foldable ;;
    "OPD2203") _dbn="OnePlus Pad (2023)"; _dbc="aries-o"; _dbf=tablet ;;
    "OPD2304"|"OPD2305") _dbn="OnePlus Pad Go"; _dbc="bluey-o"; _dbf=tablet ;;
    "OPD2407") _dbn="OnePlus Pad (2024)"; _dbc="dunhuang-o"; _dbf=tablet ;;
    "OPD2404") _dbn="OnePlus Pad Pro"; _dbc="rainbow"; _dbf=tablet ;;
    "OPD2403") _dbn="OnePlus Pad 2 (2024)"; _dbc="rainbow"; _dbf=tablet ;;
    "OPD2413") _dbn="OnePlus Pad 2 Pro"; _dbc="erhai-o"; _dbf=tablet ;;
    "OPD2415") _dbn="OnePlus Pad 3"; _dbc="erhai-o"; _dbf=tablet ;;
    "OPD2480"|"OPD2481") _dbn="OnePlus Pad Lite"; _dbc="fiji-o"; _dbf=tablet ;;
    "OPD2504"|"OPD2505") _dbn="OnePlus Pad Go 2"; _dbc="greenland-o"; _dbf=tablet ;;
    "OPD2508") _dbn="OnePlus Pad 2 (2025)"; _dbc="himalayan-o"; _dbf=tablet ;;
    "OPD2513") _dbn="OnePlus Pad 3 Pro"; _dbc="iceland-o"; _dbf=tablet ;;
    "OPD2514") _dbn="OnePlus Pad 4"; _dbc="iceland-o"; _dbf=tablet ;;
    *) return 1 ;;
  esac
  return 0
}

asb_db_soc() {
  _dsm=""; _dsn=""; _dsv=""; _dsk=""
  _dsi="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_dsi" in
    canoe) _dsi=sm8850 ;;
    sun) _dsi=sm8750 ;;
    pineapple) _dsi=sm8650 ;;
    cliffs) _dsi=sm8635 ;;
    kalama) _dsi=sm8550 ;;
    taro) _dsi=sm8450 ;;
    lahaina) _dsi=sm8350 ;;
    kona) _dsi=sm8250 ;;
  esac
  case "$_dsi" in
    sm8850*) _dsn="Snapdragon 8 Elite Gen 5"; _dsk=flagship ;;
    sm8845*) _dsn="Snapdragon 8 Gen 5"; _dsk=flagship ;;
    sm8750*) _dsn="Snapdragon 8 Elite"; _dsk=flagship ;;
    sm8735*) _dsn="Snapdragon 8s Gen 4"; _dsk=high ;;
    sm8650*) _dsn="Snapdragon 8 Gen 3"; _dsk=high ;;
    sm8635*) _dsn="Snapdragon 8s Gen 3"; _dsk=high ;;
    sm8550*) _dsn="Snapdragon 8 Gen 2"; _dsk=high ;;
    sm8475*) _dsn="Snapdragon 8+ Gen 1"; _dsk=high ;;
    sm8450*) _dsn="Snapdragon 8 Gen 1"; _dsk=high ;;
    sm8350*) _dsn="Snapdragon 888"; _dsk=upper_mid ;;
    sm8250*) _dsn="Snapdragon 865/870"; _dsk=upper_mid ;;
    sm7675*) _dsn="Snapdragon 7+ Gen 3"; _dsk=upper_mid ;;
    sm7475*) _dsn="Snapdragon 7+ Gen 2"; _dsk=upper_mid ;;
    sm7550*) _dsn="Snapdragon 7 Gen 3"; _dsk=mid ;;
    sm6450*) _dsn="Snapdragon 6 Gen 1"; _dsk=mid ;;
    sm6375*) _dsn="Snapdragon 695"; _dsk=entry ;;
    sm4450*) _dsn="Snapdragon 4 Gen 2"; _dsk=entry ;;
    sm4375*) _dsn="Snapdragon 4 Gen 1"; _dsk=entry ;;
    mt6993*) _dsn="Dimensity 9500 series"; _dsk=flagship ;;
    mt6991*) _dsn="Dimensity 9400 series"; _dsk=flagship ;;
    mt6989*) _dsn="Dimensity 9300 series"; _dsk=high ;;
    mt6985*) _dsn="Dimensity 9200 series"; _dsk=high ;;
    mt6983*) _dsn="Dimensity 9000 series"; _dsk=high ;;
    mt6899*|mt6897*|mt6896*|mt6895*) _dsk=upper_mid ;;
    mt6886*|mt6878*|mt6877*) _dsk=mid ;;
    mt6855*|mt6835*|mt6833*) _dsk=entry ;;
    sm[0-9]*|sdm[0-9]*) _dsk=unknown ;;
    mt[0-9]*) _dsk=unknown ;;
    *) return 1 ;;
  esac
  _dsm="$(printf '%s' "$_dsi" | tr 'a-z' 'A-Z')"
  case "$_dsi" in
    mt*) _dsv=MediaTek ;;
    *) _dsv=Qualcomm ;;
  esac
  [ -n "$_dsn" ] || _dsn="$_dsv $_dsm"
  return 0
}

asb_db_prop() {
  for _dbp in "$@"; do
    _dbv="$(getprop "$_dbp" 2>/dev/null)"
    [ -n "$_dbv" ] && { printf '%s' "$_dbv"; return 0; }
  done
  return 1
}

asb_db_identify() {
  _dim="$(asb_db_prop ro.product.model ro.product.vendor.model ro.product.odm.model)"
  asb_db_model "$_dim" || asb_db_model "$(asb_db_prop ro.product.vendor.model ro.product.odm.model)" || true
  _dis="$(asb_db_prop ro.soc.model)"
  asb_db_soc "$_dis" || asb_db_soc "$(asb_db_prop ro.board.platform ro.hardware.chipname)" || true
  echo "model=$_dim"
  echo "name=$_dbn"
  echo "codename=$_dbc"
  echo "form=$_dbf"
  echo "soc_model=$_dsm"
  echo "soc_name=$_dsn"
  echo "soc_vendor=$_dsv"
  echo "soc_class=$_dsk"
}

case "${0##*/}" in
  asb_device_db.sh)
    case "${1:-identify}" in
      identify) asb_db_identify ;;
      model) asb_db_model "$2" && echo "name=$_dbn codename=$_dbc form=$_dbf" ;;
      soc) asb_db_soc "$2" && echo "soc_model=$_dsm soc_name=$_dsn soc_vendor=$_dsv soc_class=$_dsk" ;;
      *) echo "usage: $0 identify|model CODE|soc SOC" >&2; exit 2 ;;
    esac
    ;;
esac
