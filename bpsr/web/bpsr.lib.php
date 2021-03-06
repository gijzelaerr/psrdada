<?PHP

include_once("functions_i.php");

define("INSTRUMENT", "bpsr");
define("CFG_FILE", "/home/dada/linux_64/share/bpsr.cfg");
define("SVD_FILE", "/home/dada/linux_64/share/bpsr_svd.cfg");
define("ROACH_FILE", "/home/dada/linux_64/share/roach.cfg");
define("BEAMS_FILE", "/home/dada/linux_64/share/bpsr_active_beams.cfg");
define("PWC_FILE", "/home/dada/linux_64/share/bpsr_pwcs.cfg");
define("CSS_FILE", "/bpsr/bpsr.css");

include_once("site_definitions_i.php");
include_once("instrument.lib.php");

class bpsr extends instrument
{

  var $roach;

  function bpsr()
  {
    instrument::instrument(INSTRUMENT, CFG_FILE, URL_FULL);

    $this->css_path = CSS_FILE;
    $this->banner_image = "/bpsr/images/bpsr_logo_480x60.png";
    $this->banner_image_repeat = "/bpsr/images/bpsr_logo_1x60.png";
    $this->fav_icon = "/bpsr/images/bpsr_favicon.ico";

    # add in the bpsr_pwcs config 
    $bpsr_pwcs = $this->configFileToHash(PWC_FILE);
    $this->config = array_merge($this->config, $bpsr_pwcs);

    $this->roach = $this->configFileToHash(ROACH_FILE);

  }

  function serverLogInfo() {

    $arr = array();
    $arr["bpsr_tcs_interface"]          = array("logfile" => "bpsr_tcs_interface.log", "name" => "TCS Interface", "tag" => "server", "shortname" => "TCS");
    $arr["bpsr_results_manager"]        = array("logfile" => "bpsr_results_manager.log", "name" => "Results Mngr", "tag" => "server", "shortname" => "Results");
    $arr["dada_pwc_command"]            = array("logfile" => "dada_pwc_command.log", "name" => "Nexus", "tag" => "server", "shortname" => "PWCC");
    $arr["bpsr_multibob_manager"]       = array("logfile" => "bpsr_multibob_manager.log", "name" => "Multibob", "tag" => "server", "shortname" => "Multibob");
    $arr["bpsr_roach_manager"]          = array("logfile" => "bpsr_roach_manager.log", "name" => "ROACH Mngr", "tag" => "server", "shortname" => "Roach mngr");
    $arr["bpsr_transfer_manager"]       = array("logfile" => "bpsr_transfer_manager.log", "name" => "Transfer Mngr", "tag" => "server", "shortname" =>"Xfer");
    $arr["bpsr_web_monitor"]            = array("logfile" => "bpsr_web_monitor.log", "name" => "Web Monitor", "tag" => "server", "shortname" => "Monitor");
    $arr["bpsr_rfi_masker"]             = array("logfile" => "bpsr_rfi_masker.log", "name" => "RFI Masker", "tag" => "server", "shortname" => "RFI");
    $arr["bpsr_pwc_monitor"]            = array("logfile" => "nexus.pwc.log", "name" => "PWC", "tag" => "pwc", "shortname" => "PWC");
    $arr["bpsr_sys_monitor"]            = array("logfile" => "nexus.sys.log", "name" => "SYS", "tag" => "sys", "shortname" => "SYS");
    $arr["bpsr_src_monitor"]            = array("logfile" => "nexus.src.log", "name" => "SRC", "tag" => "src", "shortname" => "SRC");
    $arr["bpsr_swin_tape_controller"]   = array("logfile" => "bpsr_swin_tape_controller.log", "name" => "Swin Tape", "tag" => "server", "shortname" => "SwinTape");
    $arr["bpsr_parkes_tape_controller"] = array("logfile" => "bpsr_parkes_tape_controller.log", "name" => "Parkes Tape", "tag" => "server", "shortname" => "ParkesTape");
    $arr["bpsr_raid_pipeline"]          = array("logfile" => "bpsr_raid_pipeline.log", "name" => "RAID Pipeline", "tag" => "server", "shortname" => "Pipeline");
    $arr["bpsr_frb_manager"]            = array("logfile" => "bpsr_frb_manager.log", "name" => "FRB Mgr", "tag" => "server", "shortname" => "FRB");

    return $arr;
  }

  function clientLogInfo() {

    $arr = array();
    $arr["bpsr_observation_manager"] = array("logfile" => "nexus.sys.log", "name" => "Obs Mngr", "tag" => "obs mngr");
    $arr["bpsr_pwc"]                 = array("logfile" => "nexus.pwc.log", "name" => "PWC", "tag" => "pwc");
    $arr["bpsr_proc"]                = array("logfile" => "nexus.sys.log", "name" => "Proc", "tag" => "proc");
    $arr["bpsr_events"]              = array("logfile" => "nexus.sys.log", "name" => "Event", "tag" => "evnt");
    $arr["bpsr_dumper"]              = array("logfile" => "nexus.sys.log", "name" => "Dumper", "tag" => "dump");
    $arr["bpsr_heimdall"]            = array("logfile" => "nexus.sys.log", "name" => "Heimdall", "tag" => "tran");
    $arr["bpsr_auxiliary"]           = array("logfile" => "nexus.sys.log", "name" => "Auxiliary", "tag" => "auxi");
    $arr["bpsr_results_monitor"]     = array("logfile" => "nexus.sys.log", "name" => "Results Mon", "tag" => "results mon");
    $arr["processor"]                = array("logfile" => "nexus.src.log", "name" => "Processor", "tag" => "proc");
    $arr["bpsr_disk_cleaner"]        = array("logfile" => "nexus.sys.log", "name" => "Disk Cleaner", "tag" => "cleaner");
    $arr["bpsr_transfer_raid"]       = array("logfile" => "nexus.sys.log", "name" => "Transfer RAID", "tag" => "xfer");
    $arr["bpsr_pscrunch"]            = array("logfile" => "nexus.sys.log", "name" => "Pol Scrunch", "tag" => "pscrunch");
    $arr["bpsr_dirty_send"]          = array("logfile" => "nexus.sys.log", "name" => "Dirty Send", "tag" => "dirty_send");
    $arr["bpsr_clean_recv"]          = array("logfile" => "nexus.sys.log", "name" => "Clean Recv", "tag" => "clean_send");
    $arr["bpsr_dirty_recv"]          = array("logfile" => "nexus.sys.log", "name" => "Dirty Recv", "tag" => "dirty_recv");
    $arr["bpsr_svd"]                 = array("logfile" => "nexus.sys.log", "name" => "SVD", "tag" => "svd");
    $arr["bpsr_clean_send"]          = array("logfile" => "nexus.sys.log", "name" => "Clean Send", "tag" => "clean_send");
    return $arr;

  }

  #
  # Return the source names, DM's, periods and SNRS 
  #
  function getObsSources($dir) {

     # determine how many pulsars are present
    $cmd = "find ".$dir." -maxdepth 1 -name '*.ar' -printf '%f\n'";
    $pulsars = array();
    $rval = 0;
    $line = exec($cmd, $pulsars, $rval);
    $results = array();

    for ($i=0; $i<count($pulsars); $i++) {

      $arr = split("_", $pulsars[$i], 3);
      if (count($arr) == 3)
        $p = $arr[0]."_".$arr[1];
      else
        $p = $arr[0];

      if (strpos($pulsars[$i], "_t") !== FALSE) {
        $results[$p]["int"] = instrument::getIntergrationLength($dir."/".$pulsars[$i]);
        $results[$p]["src"] = instrument::getArchiveName($dir."/".$pulsars[$i]);
        $results[$p]["dm"] =  instrument::getSourceDM($results[$p]["src"]);
        $results[$p]["p0"] =  instrument::getSourcePeriodMS($results[$p]["src"]);
        $results[$p]["nsubint"] =  instrument::getNumSubints($dir."/".$pulsars[$i]);
      }

      if (strpos($pulsars[$i], "_f") !== FALSE) {
        $results[$p]["snr"] = instrument::getSNR($dir."/".$pulsars[$i]);
      }
    }

    return $results;
  }

  function getClientStatusMessages($config) {

    $status = instrument::getPWCStatusMessages($config);

    $message_types = array("pwc", "src", "sys");
    $message_classes = array("warn", "error");
    $message_class_values = array("warn" => STATUS_WARN, "error" => STATUS_ERROR);
    $status_dir = $config["STATUS_DIR"];

    for ($i=0; $i<$config["NUM_DISTRIB"]; $i++) {
      
      $host = $config["DISTRIB_".$i];

      for ($j=0; $j<count($message_types); $j++) {

        $message_type = $message_types[$j];

        for ($k=0; $k<count($message_classes); $k++) {

          $message_class = $messsage_classes[$k];

          $fname = $status_dir."/".$host.".".$message_type.".".$message_class;
          if (file_exists($fname)) {
            $status[$host."_".$message_type."_STATUS"]  = $message_class_values[$message_class];
            $status[$host."_".$message_type."_MESSAGE"] = instrument::getSingleStatusMessage($fname);
          } else {
            $status[$host."_".$message_type."_STATUS"] = STATUS_OK;
             $status[$host."_".$message_type."_MESSAGE"] = "";
          }
        }
      }
    }

    return $status;
  }

  /*
   * Gets the most recent image/results files from a BPSR observation
   */
  function getResults($results_dir, $utc_start="latest", $type="all", $size="all", $beam="all") {

    if (strpos($results_dir, "old") !== FALSE)
      $url_link = "old_results";
    else
      $url_link = "results";

    $utc_starts = array();
    $types = array();
    $sizes = array();
    $results = array();
    $beams = array();

    if (is_array($utc_start)) {
      $utc_starts = $utc_start;
    } else if ($utc_start == "all") {
      $cmd = "find ".$results_dir." -maxdepth 1 -type d -name '2*' -printf '%f\\n' | sort";
      $str = exec($cmd, $utc_starts, $rval);
    } else if ($utc_start == "latest") {
      $cmd = "find ".$results_dir." -maxdepth 1 -type d -name '2*' -printf '%f\\n' | sort | tail -n 1";
      $str = exec($cmd, $utc_starts, $rval);
      $utc_starts = array(exec($cmd));
    } else {
      $utc_starts = array($utc_start);
    }

    if (is_array($type)) {
      $types = $type;
    } else if ($type == "all") {
      $types = array("bp", "ts", "fft", "dts","pvf");
    } else {
      $types = array($type);
    }
                                                                                                               
    if (is_array($size)) {
      $sizes = $size;
    } else if ($size == "all") {
      $sizes = array("1024x768", "400x300", "112x84");
    } else {
      $sizes = array($size);
    }

    if (is_array($beam)) {
      $beams = $beam;
    } else if ($beam == "all") {
      # get a listing of the currently configured beams
      for ($i=0; $i<$this->config["NUM_PWC"]; $i++) {
        array_push($beams, $this->roach["BEAM_".$i]);
      }
    } else {
      $beams = array($beam);
    }

    foreach ($utc_starts as $u) {

      $dir = $results_dir."/".$u;

      // find any transient candidates images
      $img = "";
      $cmd = "find ".$dir." -mindepth 1 -maxdepth 1 -type f -name '*.cands_1024x768.png' -printf '%f\\n' | sort -n | tail -n 1";
      $find_result = exec($cmd, $array, $return_val);
      if (($return_val == 0) && (strlen($find_result) > 1)) {
        $img = "/bpsr/".$url_link."/".$u."/".$find_result;
      }
      $results[$u]["transients"]["cands_1024x768"] = $img;

      /* now find the 13 files requested */
      if ($handle = opendir($dir)) {
        while (false !== ($file = readdir($handle))) {

          if ($file != "." && $file != "..") {

            $beamid = (int) $file;

            /* If this is a beam?? subdirectory */
            if ( (is_dir($dir."/".$file)) && (ereg("^([0-9][0-9])$", $file)) ) {

              /* Get into a relative dir... */
              chdir($dir);

              # echo "bpsr.lib.php: getResults: ".$dir."/".$file."<BR>\n";

              if (in_array($beamid, $beams)) {

                # Foreach image type
                foreach ($types as $t) {

                  foreach ($sizes as $s) {
      
                    $img = "/images/blankimage.gif";
                    /* Find the hi res images */
                    $cmd = "find ".$file." -name \"*.".$t."_".$s.".png\" | sort -n";
                    # echo "bpsr.lib.php: getResults: ".$cmd."<BR>\n";
                    $find_result = exec($cmd, $array, $return_val);
                    if (($return_val == 0) && (strlen($find_result) > 1)) {
                      $img = "/bpsr/".$url_link."/".$u."/".$find_result;
                    }
                    $results[$u][($beamid-1)][$t."_".$s] = $img;
                  }
                }
              }
            }
          }                                                                                                   
        }
        closedir($handle);
      } else {
        echo "Could not open plot directory: ".$dir."<BR>\n";
      }
    }

    return $results;
  }

  #
  # return an array of images for the beam (or all beams) 
  #  
  function getStatsResults($results_dir, $beam)
  {

    $dir = $results_dir."/stats";

    $results = array();
    if ($beam == "all") 
    {
      for ($i=0; $i<$this->config["NUM_PWC"]; $i++) {
        $results[$this->roach["BEAM_".$i]] = array();
      }
    } else {
      $results[$beam] = array();
    }

    // now find the 13 files requested
    if ($handle = opendir($dir)) {

      $files = array();

      # read all the files
      while ($file = readdir($handle)) {
        if ( ($file != ".") && ($file != "..") ) {
          array_push($files, $file);
        }
      }

      closedir($handle);
      sort($files);

      # Now ensure we have only the most recent files in the array
      foreach ($results as $key => $value) 
      {
        $beam = $key;

        for ($j=0; $j<count($files); $j++) 
        {
          if (strpos($files[$j], "cross") !== FALSE)
            $type = "pdcp";
          else if (strpos($files[$j], "hist") !== FALSE)
            $type = "pdhg";
          else
            $type = "pdbp";

          if (strpos($files[$j], $beam."_112x84") !== FALSE)
          {
            $value[$type."_112x84"] = "/bpsr/results/stats/".$files[$j];
          }
          if (strpos($files[$j], $beam."_400x300") !== FALSE)
          {
            $value[$type."_400x300"] = "/bpsr/results/stats/".$files[$j];
          }
          if (strpos($files[$j], $beam."_1024x768") != FALSE)
          {
            $value[$type."_1024x768"] = "/bpsr/results/stats/".$files[$j];
          }
        }
        $results[$key] = $value;
      }

    } else {
       echo "Could not open plot directory: ".$dir."<BR>\n";
    }

    return $results;

  }

  #
  # return information abuot the specified result[s]
  #
  function getResultsInfo($observations, $results_dir) 
  {

    if (!is_array($observations)) {
      $observations = array($observations);
    }

    $data = array();

    foreach ($observations as $i => $o) {

      $data[$o] = array();

      $obs_dir = $results_dir."/".$o;

      $freq_channels = getSubDirs($obs_dir);
      $data[$o]["nbeams"] = count($freq_channels);

      $cmd = "find ".$obs_dir." -name \"obs.start\" | tail -n 1";
      $an_obs_start = exec($cmd);
      $data[$o]["obs_start"] = $an_obs_start;

      if (file_exists($obs_dir."/obs.txt")) {
        $data[$o]["annotation"] = exec("cat ".$obs_dir."/obs.txt");
      } else {
        $data[$o]["annotation"] = "";
      }

      for ($j=0; $j<count($freq_channels); $j++) {
        $data[$o][$j]["dir"] = "/results/".$o."/".$freq_channels[$j];
      }
    }

    return $data;
  }

  #
  # return state information about the specified observation
  #
  function getObservationState($o)
  {
    $results = array();

    if (file_exists($this->config["SERVER_RESULTS_DIR"]."/".$o))
      $dir = $this->config["SERVER_RESULTS_DIR"]."/".$o;
    else if (file_exists($this->config["SERVER_OLDRESULTS_DIR"]."/".$o))
      $dir = $this->config["SERVER_OLD_RESULTS_DIR"]."/".$o;
    else
      return $results;

    if (file_exists($dir."/obs.deleted"))
      $state = "Deleted";
    else if (file_exists($dir."/obs.transferred"))
      $state = "Transferred";
    else if (file_exists($dir."/obs.finished"))
      $state = "Finished";
    else if (file_exists($dir."/obs.processing"))
      $state = "Processing";
    else if (file_exists($dir."/obs.new"))
      $state = "New";
    else
      $state = "Unknown";

    $results["ARCHIVAL_STATE"] = $state;
    $results["BEAM_SIZE"] = "N/A";

    return $results;
  }

  #
  # Return the Beam number for the specified host
  # 
  function getBeamForPWCHost($host)
  {
    $beam = 0;
/*
    for ($i=0; $i<$this->ibobs["NUM_IBOB"]; $i++)
    {
      if ($this->ibobs["10GbE_CABLE_".$i] == $host)
      {
        $beam = $this->ibobs["BEAM_".$i];
      }
    }
*/
    return $beam;
  }

  #
  # Return an array of valid BPSR project IDs
  #
  function getPIDS()
  {
    $cmd = "groups bpsr";
    $output = array();
    $return_var = 0;

    $string = exec($cmd, $output, $return_var);
    $array = explode(" ",$string);
    $groups = array();
    for ($i=0; $i<count($array); $i++) {
      if (strpos($array[$i], "P") === 0) {
        array_push($groups, $array[$i]);
      }
    }
    sort($groups);
    return $groups;
  }

  #
  # Return an array of Destinations for BPSR PIDs
  # 
  function getPIDDestinations()
  {
    $pids = $this->getPIDS();
    $pid_dests = array();

    for ($i=0; $i<count($pids); $i++)
    {
      if (array_key_exists($pids[$i]."_DEST", $this->config))
        $pid_dests[$pids[$i]] = $this->config[$pids[$i]."_DEST"];
    }
    return $pid_dests;
  }
  

} // END OF CLASS DEFINITION
