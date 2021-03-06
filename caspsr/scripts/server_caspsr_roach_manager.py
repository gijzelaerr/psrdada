#!/usr/bin/env python26
#
# Filename: server_bpsr_roach_manager.py
#
#   * load firmware and config roaches for use with BPSR
#   * allow level setting
#   * allow rearming
#   * retrieve bram data

import Dada, Bpsr, threading, sys, time, socket, select, signal, traceback
import corr, time, numpy, math, os

PIDFILE  = "bpsr_roach_manager.pid"
LOGFILE  = "bpsr_roach_manager.log"
QUITFILE = "bpsr_roach_manager.quit"
DL = 1

QUIT = 1
IDLE = 2
ERROR = 3
TASK_STATE = 4
TASK_CONFIG = 5
TASK_ARM = 6
TASK_SET_LEVELS = 7
TASK_BRAMPLOT = 8

###########################################################################

def signal_handler(signal, frame):
  print 'You pressed Ctrl+C!'
  global quit_event
  quit_event.set()
  
# Thread to operate on Roach
class roachThread(threading.Thread):

  def __init__(self, roach_num, quit_event, cond, lock, states, results, cfg):
    threading.Thread.__init__(self)
    self.roach_num = roach_num
    self.quit_event = quit_event
    self.cond = cond
    self.lock = lock
    self.states = states
    self.results = results
    self.cfg = cfg

  def run(self):
    rid = str(self.roach_num)
    ithread = self.roach_num
    cfg = self.cfg
    lock = self.lock
    cond = self.cond
    states = self.states
    results = self.results
    fpga = []
    locked = False
    acc_len = 25
    roach_cfg = Bpsr.getROACHConfig()
    roach_name = roach_cfg["ROACH_IP_"+rid]
    os.chdir(cfg["SERVER_STATS_DIR"]);

    try:

      Dada.logMsg(1, DL, "roachThread["+rid+"]: starting")

      # acquire lock to wait for commands setup
      locked = lock.acquire()
      Dada.logMsg(2, DL, "roachThread["+rid+"]: lock acquired")

      while (states[ithread] != QUIT):
        while (states[ithread] == IDLE):
          Dada.logMsg(2, DL, "roachThread["+rid+"]: waiting for not IDLE")
          locked = False
          cond.wait()
          locked = True
        if (states[ithread] == QUIT):
          Dada.logMsg(1, DL, "roachThread["+rid+"]: quit requested")
          lock.release()
          loacked = False
          return

        # we have been given a command to perform (i.e. not QUIT or IDLE)
        task = states[ithread]
        Dada.logMsg(2, DL, "roachThread["+rid+"]: TASK="+str(task))

        Dada.logMsg(2, DL, "roachThread["+rid+"]: lock.release()")
        lock.release()
        locked = False
  
        result = "fail"

        if (task == TASK_STATE):
          Dada.logMsg(2, DL, "roachThread["+rid+"]: state request")
          if (fpga != []):
            result = "ok"

        elif (task == TASK_CONFIG):
          Dada.logMsg(2, DL, "roachThread["+rid+"]: perform config")
          result, fpga = Bpsr.configureRoach (DL, acc_len, rid, cfg)
          if (result != "ok"):
            Dada.logMsg(-2, DL, "roachThread["+rid+"]: roach not ready")
            fpga = []

        elif (task == TASK_ARM):
          Dada.logMsg(2, DL, "roachThread["+rid+"]: perform arm")
          if (fpga != []):
            result = Bpsr.armRoach(DL, fpga)

        elif (task == TASK_SET_LEVELS):
          Dada.logMsg(2, DL, "roachThread["+rid+"]: perform set levels")
          if (fpga != []):
            result = Bpsr.setLevels(DL, fpga)

        elif (task == TASK_BRAMPLOT):
          if (fpga != []):
            Dada.logMsg(2, DL, "roachThread["+rid+"]: perform bramplot")
            time_str = Dada.getCurrentDadaTime()
            result = Bpsr.bramplotRoach(DL, fpga, time_str, roach_name)
          else:
            Dada.logMsg(-1, DL, "roachThread["+rid+"]: not connected to FPGA")
          
        else:
          Dada.logMsg(2, DL, "roachThread["+rid+"]: unrecognised task!!!")

        # now that task is done, re-acquire lock
        Dada.logMsg(2, DL, "roachThread["+rid+"]: lock.acquire()")
        locked = lock.acquire()
        Dada.logMsg(2, DL, "roachThread["+rid+"]: setting state = IDLE")
        states[ithread] = IDLE
        results[ithread] = result
        Dada.logMsg(2, DL, "roachThread["+rid+"]: cond.notifyAll()")
        cond.notifyAll()
    
    except:

      print '-'*60
      traceback.print_exc(file=sys.stdout)
      print '-'*60

      quit_event.set()
      if (not locked):
        Dada.logMsg(0, DL, "roachThread["+rid+"]: except: lock.acquire()")
        locked = lock.acquire()
      Dada.logMsg(0, DL, "roachThread["+rid+"]: except: setting state = ERROR")
      states[ithread] = ERROR
      results[ithread] = "fail"
      Dada.logMsg(2, DL, "roachThread["+rid+"]: except: cond.notifyAll()")
      cond.notifyAll()
      Dada.logMsg(2, DL, "roachThread["+rid+"]: except: lock.release()")
      lock.release()
      Dada.logMsg(2, DL, "roachThread["+rid+"]: except: exiting")
      return

     # we have been asked to exit the rthread
    Dada.logMsg(1, DL, "roachThread["+rid+"]: end of thread")


# Thread to handle commands
class commandThread(threading.Thread):

  def __init__(self, quit_event, cond, lock, states, results, cfg):
    threading.Thread.__init__(self)
    self.quit_event = quit_event
    self.cond = cond
    self.lock = lock
    self.states = states
    self.results = results
    self.cfg = cfg

  def run(self):
    self.quit_event = quit_event
    cond = self.cond
    lock = self.lock
    states = self.states
    results = self.results
    cfg = self.cfg

    try:

      Dada.logMsg(2, DL, "commandThread: starting")

      # open a socket to receive commands via socket, allow 1 connection
      hostname = Dada.getHostMachineName()
      sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
      sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
      Dada.logMsg(2, DL, "commandThread: binding to "+hostname+":"+cfg["IBOB_MANAGER_PORT"])
      sock.bind((hostname, int(cfg["IBOB_MANAGER_PORT"])))

      # listen for at most 2 connections at a time (TCS and self)
      Dada.logMsg(2, DL, "commandThread: sock.listen(2)")
      sock.listen(2)

      can_read = [sock]
      can_write = []
      can_error = []
      timeout = 1

      valid_commands = dict({ "QUIT":QUIT, \
                              "STATE":TASK_STATE, \
                              "CONFIG":TASK_CONFIG, \
                              "ARM":TASK_ARM, \
                              "SET_LEVELS":TASK_SET_LEVELS, \
                              "BRAMPLOT":TASK_BRAMPLOT})

      # keep listening
      while ((not quit_event.isSet()) or (len(can_read) > 1)):

        Dada.logMsg(2, DL, "commandThread: calling select len(can_read)="+str(len(can_read)))
        did_read, did_write, did_error = select.select(can_read, can_write, can_error, timeout)
        Dada.logMsg(3, DL, "commandThread: read="+str(len(did_read))+" write="+str(len(did_write))+" error="+str(len(did_error)))  

        # if we did_read
        if (len(did_read) > 0):
          for handle in did_read:
            if (handle == sock):
              (new_conn, addr) = sock.accept()
              Dada.logMsg(2, DL, "commandThread: accept connection from "+repr(addr))
              # add the accepted connection to can_read
              can_read.append(new_conn)
            # an accepted connection must have generated some data
            else:
              message = handle.recv(4096)
              message = message.strip()
              Dada.logMsg(2, DL, "commandThread: message='" + message+"'")
              if (len(message) == 0):
                Dada.logMsg(2, DL, "commandThread: closing connection")
                handle.close()
                for i, x in enumerate(can_read):
                  if (x == handle):
                    del can_read[i]
              else:

                message = message.upper()
                if ((message == "BRAMPLOT") or (message == "STATE")):
                  qdl = 2
                else:
                  qdl = 1

                Dada.logMsg(qdl, DL, "<- " + message)

                if (message in valid_commands.keys()):
                
                  command = valid_commands[message]
                  Dada.logMsg(2, DL, "commandThread: " + message + " was valid, index=" + str(command))

                  if (command == QUIT):
                    handle.send("ok\r\n")
                    Dada.logMsg(1, DL, " -> ok")
                    quit_event.set()

                    # remove the server socket from the list of can_reads
                    for i, x in enumerate(can_read):
                      if (x == sock):
                        Dada.logMsg(2, DL, "commandThread: removed sock from can_read")
                        del can_read[i]

                    Dada.logMsg(2, DL, "commandThread: closing server socket [1]")
                    sock.close()
                    sock = []
              
                  else:
                    # now process this message
                    Dada.logMsg(2, DL, "commandThread: lock.acquire()")
                    lock.acquire()
                    Dada.logMsg(2, DL, "commandThread: lock acquired")

                    for i in range(n_roach):
                      roach_states[i] = command 
                    roach_state = command 
                    Dada.logMsg(3, DL, "commandThread: states set to " + message)

                    # all commands should happen as soon as is practical, expect
                    # for the arm, which should ocurr very close to 0.5 seconds
                    # through a second. This command should also return the UTC time
                    # corresponding to the expected start
                    if (command == TASK_ARM):
                      # busy sleep until the next second ticks over
                      curr_time = int(time.time())
                      next_time = curr_time
                      Dada.logMsg(2, DL, "commandThread: waiting for 1 second boundary")
                      while (curr_time == next_time):
                        next_time = int(time.time())
                      Dada.logMsg(2, DL, "commandThread: sleeping 0.5 seconds")
                      time.sleep(0.5)
                      utc_start = Dada.getUTCDadaTime(1)
                      Dada.logMsg(2, DL, "commandThread: UTC_START=" + utc_start)

                    # activate threads
                    Dada.logMsg(3, DL, "commandThread: cond.notifyAll()")
                    cond.notifyAll()
                    Dada.logMsg(3, DL, "commandThread: lock.release()")
                    lock.release()

                    # wait for all roaches to finished the command
                    Dada.logMsg(3, DL, "commandThread: lock.acquire()")
                    lock.acquire()
                    Dada.logMsg(3, DL, "commandThread: lock acquired")

                    command_result = ""
                    command_response = ""

                    while (roach_state == command):
                      Dada.logMsg(2, DL, "commandThread: checking all roaches for IDLE")

                      n_idle = 0
                      n_error = 0
                      n_running = 0
                      n_ok = 0
                      n_fail = 0

                      for i in range(n_roach):
                        Dada.logMsg(2, DL, "commandThread: testing roach["+str(i)+"]")

                        # check the states of each roach thread
                        if (roach_states[i] == IDLE):
                          n_idle += 1
                        # check the return values of this roach
                          Dada.logMsg(2, DL, "commandThread: roach_results["+str(i)+"] = " + roach_results[i])
                          if (roach_results[i] == "ok"):
                            n_ok += 1
                          else:
                            n_fail += 1
                        elif (roach_states[i] == ERROR):
                          Dada.logMsg(-1, DL, "commandThread: roach["+str(i)+"] thread failed")
                          n_error += 1
                        else:
                          n_running += 1


                      # if all roach threads are idle, we are done - extract the results
                      if (n_idle == n_roach):

                        roach_state = IDLE
                        if (n_ok == n_roach):
                          command_result = "ok"
                        else:
                          command_result= "fail";
                          for i in range(n_roach):
                            command_response = command_response + "roach"+str(i)+":"+str(roach_results[i])+" "

                      elif (n_error > 0):
                        Dada.logMsg(2, DL, "commandThread: roach thread error")
                        command_result = "fail";
                        command_response = str(n_error) + " roach threads failed";
                        roach_state = ERROR

                      else:
                        Dada.logMsg(2, DL, "commandThread: NOT all IDLE, cond.wait()")
                        cond.wait()
  
                    if (command == TASK_ARM):
                      if (command_response != ""):
                        command_response = command_response + "\r\n" + "UTC_START=" + utc_start
                      else:
                        command_response = "UTC_START="+utc_start

                    if (command_response != ""):
                      handle.send(command_response + "\r\n") 
                      Dada.logMsg(qdl, DL, "-> " + command_response)

                    handle.send(command_result + "\r\n")
                    Dada.logMsg(qdl, DL, "-> " + command_result)

                    Dada.logMsg(2, DL, "commandThread: lock.release()")
                    lock.release()

                else:
                  Dada.logMsg(2, DL, "commandThread: unrecognised command")
                  Dada.logMsg(1, DL, " -> fail")
                  handle.send("fail\r\n")

    except:
      Dada.logMsg(-2, DL, "commandThread: exception caught: " + str(sys.exc_info()[0]))
      print '-'*60
      traceback.print_exc(file=sys.stdout)
      print '-'*60

    if (not sock == []): 
      Dada.logMsg(2, DL, "commandThread: closing server socket [2]")
      sock.close()

    Dada.logMsg(2, DL, "commandThread: exiting")     


############################################################################### 
#
# main
#

try:

  # get the BPSR configuration
  cfg = Bpsr.getConfig()
  roach_cfg = Bpsr.getROACHConfig()

  log_file = cfg["SERVER_LOG_DIR"] + "/" + LOGFILE;
  pid_file = cfg["SERVER_CONTROL_DIR"] + "/" + PIDFILE;
  quit_file = cfg["SERVER_CONTROL_DIR"] + "/"  + QUITFILE;
  quit_event = threading.Event()

  # become a daemon
  # Dada.daemonize(pid_file, log_file)

  signal.signal(signal.SIGINT, signal_handler)

  # start a control thread to handle quit requests
  control_thread = Dada.controlThread(quit_file, pid_file, quit_event, DL);
  control_thread.start()

  # start a thread for each ROACH board
  lock = threading.Lock()
  cond = threading.Condition(lock)
  roach_threads = []
  roach_states = []
  roach_results = []
  n_roach = int(roach_cfg["NUM_ROACH"])

  for i in range(n_roach):
    roach_states.append(IDLE)
    roach_results.append("")
    thr = roachThread(i, quit_event, cond, lock, roach_states, roach_results, cfg)
    thr.start()
    roach_threads.append(thr)

  # start a thread to handle socket commands that will interact with the ROACH threads
  Dada.logMsg(2, DL, "main: starting command thread")
  command_thread = commandThread(quit_event, cond, lock, roach_states, roach_results, cfg)
  command_thread.start()

  # allow some time for commandThread to open listening socket
  time.sleep(2)

  # open a socket to the command thread
  hostname = Dada.getHostMachineName()
  port =  int(cfg["IBOB_MANAGER_PORT"])

  # wait for all roaches to be active, then start bramdumping till exit
  roaches_all_active = False
  command_sock = 0
  
  while (not quit_event.isSet()):

    Dada.logMsg(2, DL, "main: while loop")

    if (command_sock == 0):
      Dada.logMsg(2, DL, "main: openSocket("+hostname+", "+str(port)+")")
      command_sock = Dada.openSocket(DL, hostname, port)
      Dada.logMsg(2, DL, "main: command_sock="+repr(command_sock))

    # see if roaches are all active
    if ((not roaches_all_active) and (command_sock != 0)):

      Dada.logMsg(2, DL, "main: <- 'state'")
      result, response = Dada.sendTelnetCommand(command_sock, 'state')
      Dada.logMsg(2, DL, "main: -> " + result + " " + response)

      if (result == "ok"):
        roaches_all_active = True 
    
    # if roaches are all active, bramplot 'em
    if (roaches_all_active):
      Dada.logMsg(2, DL, "main: <- 'bramplot'")
      result, response = Dada.sendTelnetCommand(command_sock, 'bramplot')
      Dada.logMsg(2, DL, "main: -> " + result + " " + response)
      
    counter = 5
    while ((not quit_event.isSet()) and (counter > 0)):
      counter -= 1
      Dada.logMsg(2, DL, "main: sleeping")
      time.sleep(1)

  Dada.logMsg(2, DL, "main: command_sock.close()")
  command_sock.close()

  # join the command therad
  Dada.logMsg(2, DL, "main: joining command thread")
  command_thread.join()
  Dada.logMsg(2, DL, "main: command thread joined")

except:
  Dada.logMsg(-2, DL, "main: exception caught: " + str(sys.exc_info()[0]))
  print '-'*60
  traceback.print_exc(file=sys.stdout)
  print '-'*60
  quit_event.set()

Dada.logMsg(2, DL, "main: lock.acquire()")
lock.acquire()
Dada.logMsg(2, DL, "main: lock acquired")

for i in range(n_roach):
  roach_states[i] = QUIT
roach_state = QUIT

Dada.logMsg(2, DL, "main: cond.notifyAll()")
cond.notifyAll()
Dada.logMsg(2, DL, "main: lock.release()")
lock.release()

# join threads
Dada.logMsg(2, DL, "main: joining control thread")
control_thread.join()

Dada.logMsg(2, DL, "main: joining roach threads")
for i in range(n_roach):
  Dada.logMsg(2, DL, "main: joining roach thread["+str(i)+"]")
  roach_threads[i].join()

Dada.logMsg(2, DL, "main: exiting")

Dada.logMsg(1, DL, "STOPPING SCRIPT")
# exit
sys.exit(0)


