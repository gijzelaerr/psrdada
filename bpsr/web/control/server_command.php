<?PHP
include("../definitions_i.php");
include("../functions_i.php");

if (!IN_CONTROL) {

  $hostname = strtolower(gethostbyaddr($_SERVER["REMOTE_ADDR"]));
  $controlling_hostname = strtolower(rtrim(file_get_contents(CONTROL_FILE)));
                                                                                                                                          
  echo "<html>\n";
  include("../header_i.php");
  ?>
  <br>
  <h3><font color="red">You cannot make any changes to the instrument if your host is not in control.</font></h3>
                                                                                                                                          
  <p>Controlling host: <?echo $controlling_hostname?>
     Your host: <?echo $hostname?></p>
                                                                                                                                          
  <!-- Force reload to prevent additional control attempts -->
  <script type="text/javascript">
  parent.control.location.href=parent.control.location.href;
  </script>
                                                                                                                                          
  </body>
  </html>
<?
  exit(0);

}

?>
<html>
<?
include("../header_i.php");

$cmd         = $_GET["cmd"];
$config      = getConfigFile(SYS_CONFIG);
$host        = $config["SERVER_HOST"];
$control_dir = $config["SERVER_CONTROL_DIR"];

chdir($config["SCRIPTS_DIR"]);

$return_val = 0;

$server_daemons = split(" ",$config["SERVER_DAEMONS"]);
for ($i=0; $i<count($server_daemons);$i++) {
  $server_names[$i] = str_replace("_", " ", $server_daemons[$i]);
}

?>
  <script type="text/javascript">
    function finish(){
      parent.control.location.href=parent.control.location.href;
    }
  </script>
<body>
<center>
<?

/* Start the server side daemons */
if ($cmd == "start_daemons") {

?>

<table class="datatable">
  <tr><th colspan=3>Starting Server Daemons</th></tr>
  <tr><th width="20%">Daemon</th><th width="10%">Result</th><th width="70%">Messages</th></tr>
<?
  for ($i=0; $i<count($server_daemons); $i++) {
    $return_val += startDaemon($server_names[$i], $server_daemons[$i]);
    flush();
  }

?>

</table>
<?

} else if ($cmd == "stop_daemons") {
?>

<table class="datatable">
  <tr><th colspan=3>Stopping Server Daemons</th></tr>
  <tr><th>Daemon</th><th>Result</th><th>Messages</th></tr>

<?

  system("touch ".$control_dir."/quitdaemons");

  for ($i=0; $i<count($server_daemons); $i++) {
    $return_val += waitForDaemon($server_names[$i], $server_daemons[$i], $control_dir);
    flush();
  }

  unlink($control_dir."/quitdaemons");

?>
  </table>
<?

} else if ($cmd == "reset_pwcc") {

  echo "opening socket to ".$config["PWCC_HOST"].":".$config["PWCC_PORT"]."<BR>\n";

  flush();

  list($socket, $result) = openSocket($config["PWCC_HOST"], $config["PWCC_PORT"], 10);

  if ($result == "ok") {

    echo "Socket open<BR>\n";
    flush();

    echo "Read: ".socketRead($socket)."<BR>\n";;
    flush();

    socketWrite($socket, "reset\r\n");
    flush();

    echo "Read: ".socketRead($socket)."<BR>\n";;
    flush();

  } else {

    echo "Could not open socket to ".$config["PWCC_HOST"].":".$config["PWCC_PORT"]."<BR>\n";

  }

} else if ($cmd == "restart_all") {

?>
<table class="datatable" width=60%>
  <tr><th colspan=1>Restarting BPSR</th></tr>

<?
  flush();

  $script_name = "bpsr_reconfigure.pl";
  echo "  <tr style=\"background: white;\">\n";
  echo "    <td align=\"left\">\n";
  $script = "source /home/dada/.bashrc; ".$script_name." 2>&1";
  $string = exec($script, $output, $return_var);
  for ($i=0; $i<count($output); $i++) {
    echo $output[$i]."<BR>";
  }
  echo "    </td>\n";
  echo "  </tr>\n";
  echo "</table>\n";

} else if ($cmd == "stop_bpsr") {
                                                                                                                                                                                                
?>
<table class="datatable" width=60%>
  <tr><th colspan=1>Stopping BPSR</th></tr>
                                                                                                                                                                                                
<?
  flush();
                                                                                                                                                                                                
  $script_name = "bpsr_reconfigure.pl -s";
  echo "  <tr style=\"background: white;\">\n";
  echo "    <td align=\"left\">\n";
  $script = "source /home/dada/.bashrc; ".$script_name." 2>&1";
  $string = exec($script, $output, $return_var);
  for ($i=0; $i<count($output); $i++) {
    echo $output[$i]."<BR>";
  }
  echo "    </td>\n";
  echo "  </tr>\n";
  echo "</table>\n";


} else if ($cmd == "start_bpsr") {
                                                                                                                                                                                                
?>
<table class="datatable" width=60%>
  <tr><th colspan=1>Starting BPSR</th></tr>
                                                                                                                                                                                                
<?
  flush();
                                                                                                                                                                                                
  $script_name = "bpsr_reconfigure.pl -i";
  echo "  <tr style=\"background: white;\">\n";
  echo "    <td align=\"left\">\n";
  $script = "source /home/dada/.bashrc; ".$script_name." 2>&1";
  $string = exec($script, $output, $return_var);
  for ($i=0; $i<count($output); $i++) {
    echo $output[$i]."<BR>";
  }
  echo "    </td>\n";
  echo "  </tr>\n";
  echo "</table>\n";

} else if ($cmd == "get_gains") {

  echo "Opening socket<BR>\n";
  list($socket, $result) = openSocket($config["SERVER_HOST"], $config["SERVER_GAIN_REPORT_PORT"], 10);

  if ($result != "ok") {

    echo "Could not open socket<BR>\n";

  } else {
  
    socketWrite($socket, "REPORT GAINS\r\n");
    echo "Wrote \"REPORT GAINS\"<BR>\n";
    flush();

    echo "Reading Reponse...\n";
    flush();
    $response = rtrim(socketRead($socket));
    echo "Read\"".$response."\"<BR>\n";
    flush();

    echo "Closing socket<BR>\n";
    flush();
    socket_close($socket);

    echo "Closed socket<BR>\n";
  }

  flush();

} else {

  $result = "fail";
  $response = "Unrecognized command";

}
flush();
sleep(1);

if (!$return_val) {
?>
<script type="text/javascript">finish()</script>
<? } ?>
</center>
</body>
</html>

<?

function startDaemon($title, $name) {

  $script_name = "./server_".$name.".pl";

  echo "  <tr style=\"background: white;\">\n";
  echo "    <td>".$title."</td>\n";
  $script = "source /home/dada/.bashrc; ".$script_name." 2>&1";
  $string = exec($script, $output, $return_var);
  echo "    <td>";
  echo ($return_var == 0) ? "OK" : "FAIL";
  echo "</td>\n";
  echo "    <td>";
  for ($i=0;$i<count($output);$i++) {
    echo $output[$i]."<BR>\n";
  }
  echo "</td>\n";
  echo "  </tr>\n";

  return $return_var;

}

function waitForDaemon($title, $name, $dir) {

  $cmd = "ps auxwww | grep \"perl ./".$name."\" | grep -v grep";

  $pid_file = $dir."/".$name.".pid";

  $daemon_running = 1;
  $nwait = 5;

  while (($daemon_running) && ($nwait > 0)) {

    $last_line = system($cmd, $ret_val);

    if (((file_exists($pid_file)) || ($ret_val == 0)) && ($nwait < 5)) {
      echo "<tr style=\"background: white;\"><td>".$title."</td><td>FAIL</td><td>still running...</td>";
    } else {
      echo "<tr style=\"background: white;\"><td>".$title."</td><td>OK</td><td>Daemon Exited</td>";
      $daemon_running = 0; 
    }
    sleep(1);
    $nwait--;
  }

  if ($daemon_running) {
    return 1;
  } else {
    return 0;
  }

}
