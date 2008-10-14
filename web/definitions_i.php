<?PHP

/* Determine the current intsrument */
include("instrument_i.php");
include(INSTRUMENT."/definitions_i.php");

/* Directory configuration */

define(DADA_ROOT,  "/home/dada/linux_64");
define(WEB_BASE,   DADA_ROOT."/web");

define(CHANGE_INSTRUMENT_FILE, "/tmp/".INSTRUMENT."/control/change_instrument");

define(STATUS_FILE_DIR, WEB_BASE."/status");
define(PLOT_DIR,        WEB_BASE."/plots");
define(RESULTS_DIR,     WEB_BASE."/results");

/* Config files */
define(SYS_CONFIG,         readlink(DADA_ROOT."/share/dada.cfg"));
define(DADA_CONFIG,        DADA_ROOT."/share/tcs.cfg");
define(DADA_SPECIFICATION, DADA_ROOT."/share/tcs.spec");

/* Time/date configuration */
define(DADA_TIME_FORMAT,  "Y-m-d-H:i:s");
define(UTC_TIME_OFFSET,   10);
define(LOCAL_TIME_OFFSET, (UTC_TIME_OFFSET*3600));

define(STATUS_OK,    "0");
define(STATUS_WARN,  "1");
define(STATUS_ERROR, "2");

define(LOG_FILE_SCROLLBACK_HOURS,6);
define(LOG_FILE_SCROLLBACK_SECS,LOG_FILE_SCROLLBACK_HOURS*60*60);

# Ports 
define(TCS_CONTROL_PORT, "59000");
define(TCS_CONTROL_HOST, "srv0.apsr.edu.au");

define(STYLESHEET_HTML,     "<link rel=\"STYLESHEET\" type=\"text/css\" href=\"/style.css\">");
define(STYLESHEET_LOG_HTML, "<link rel=\"STYLESHEET\" type=\"text/css\" href=\"/style.css\">");
define(FAVICO_HTML,         "<link rel=\"shortcut icon\" href=\"/images/favicon.ico\"/>");

?>
