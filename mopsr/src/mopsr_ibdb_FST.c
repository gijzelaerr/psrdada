/***************************************************************************
 *  
 *    Copyright (C) 2013 by Andrew Jameson
 *    Licensed under the Academic Free License version 2.1
 * 
 ****************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <signal.h>
#include <limits.h>

#include "dada_client.h"
#include "dada_hdu.h"
#include "dada_def.h"
#include "dada_msg.h"
#include "mopsr_def.h"
#include "mopsr_ib.h"

#include "node_array.h"
#include "string_array.h"
#include "ascii_header.h"

// Globals
int quit_signal = 0;

void * mopsr_ibdb_init_thread (void * arg);

void usage()
{
  fprintf (stdout,
    "mopsr_ibdb_FST [options] channel cornerturn.cfg\n"
    " -k <key>          hexadecimal shared memory key  [default: %x]\n"
    " -s                single transfer only\n"
    " -v                verbose output\n"
    " -h                print this usage\n\n"
    " channel           channel to receive data for\n"
    " cornerturn.cfg    ascii configuration file defining cornerturn\n",
    DADA_DEFAULT_BLOCK_KEY);
}

/*! Function that opens the data transfer target */
int mopsr_ibdb_open (dada_client_t* client)
{
  // the mopsr_ibdb specific data
  assert (client != 0);
  mopsr_bf_ib_t* ctx = (mopsr_bf_ib_t*) client->context;

  // the ib communcation managers
  assert(ctx->ib_cms != 0);
  dada_ib_cm_t ** ib_cms = ctx->ib_cms;

  if (ctx->verbose)
    multilog (client->log, LOG_INFO, "mopsr_ibdb_open()\n");
  
  // assumed that we do not know how much data will be transferred
  client->transfer_bytes = 0;

  // this is not used in block by block transfers
  client->optimal_bytes = 0;

  ctx->obs_ending = 0;
}

/*! Function that closes the data file */
int mopsr_ibdb_close (dada_client_t* client, uint64_t bytes_written)
{
  // the mopsr_ibdb specific data
  mopsr_bf_ib_t* ctx = (mopsr_bf_ib_t*) client->context;

  // status and error logging facility
  multilog_t* log = client->log;

  dada_ib_cm_t ** ib_cms = ctx->ib_cms;

  if (ctx->verbose)
    multilog(log, LOG_INFO, "mopsr_ibdb_close()\n");

  if (bytes_written < client->transfer_bytes) 
  {
    multilog (log, LOG_INFO, "transfer stopped early at %"PRIu64" bytes, expecting %"PRIu64"\n",
              bytes_written, client->transfer_bytes);
  }

  // if we processed a partial block in the last recv_block call, then this extra logic
  // is to allow for the mopsr_dbib_close function to cleanup the transfer
  if (ctx->obs_ending)
  {
    // send READY message to inform sender we are ready for DATA 
    if (ctx->verbose)
      multilog(ctx->log, LOG_INFO, "close: send_messages [READY DATA]\n");
    if (dada_ib_send_messages(ib_cms, ctx->nconn, DADA_IB_READY_KEY, 0) < 0)
    {
      multilog(ctx->log, LOG_ERR, "close: send_messages [READY DATA] failed\n");
      return -1;
    }

    // wait for the number of bytes to be received
    if (ctx->verbose)
      multilog(ctx->log, LOG_INFO, "close: recv_messages [EOD]\n");
    if (dada_ib_recv_messages(ib_cms, ctx->nconn, DADA_IB_BYTES_TO_XFER_KEY) < 0)
    {
      multilog(ctx->log, LOG_ERR, "close: recv_messages [EOD] failed\n");
      return -1;
    }
  }

  if (ctx->verbose)
    multilog (log, LOG_INFO, "close: transferred %"PRIu64" bytes\n", bytes_written);

  return 0;
}

/*! data transfer function, for just the header */
int64_t mopsr_ibdb_recv (dada_client_t* client, void * buffer, uint64_t bytes)
{
  mopsr_bf_ib_t * ctx = (mopsr_bf_ib_t *) client->context;

  dada_ib_cm_t ** ib_cms = ctx->ib_cms;

  multilog_t * log = client->log;

  unsigned int i = 0;

  // send READY message to inform sender we are ready for the header
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv: send_messages [READY HDR]\n");
  if (dada_ib_send_messages(ib_cms, ctx->nconn, DADA_IB_READY_KEY, 0) < 0)
  {
    multilog(ctx->log, LOG_ERR, "recv: send_messages [READY HDR] failed\n");
    return 0;
  }

  // wait for transfer of the headers
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv: wait_recv [HEADER]\n");
  for (i=0; i<ctx->nconn; i++)
  {
    if (ctx->verbose > 1)
      multilog(ctx->log, LOG_INFO, "recv: [%d] wait_recv [HEADER]\n", i);
    if (dada_ib_wait_recv(ib_cms[i], ib_cms[i]->header_mb) < 0)
    {
      multilog(ctx->log, LOG_ERR, "recv: [%d] wait_recv [HEADER] failed\n", i);
      return 0;
    }
    if (ib_cms[i]->verbose > ctx->verbose)
      ctx->verbose = ib_cms[i]->verbose;
  }

  // copy header from just first src, up to a maximum of bytes
  memcpy (buffer, ctx->ib_cms[0]->header_mb->buffer, bytes);

  unsigned old_nant, new_nant;
  if (ascii_header_get (buffer, "NANT", "%u", &old_nant) != 1)
  {
    multilog (log, LOG_ERR, "recv: failed to read NANT from header\n");
    return 0;
  }
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: old NANT=%u\n", old_nant);

  // update the NANT *= number of connections
  new_nant = old_nant * ctx->nconn;

  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: setting NANT=%u in header\n",new_nant);
  if (ascii_header_set (buffer, "NANT", "%u", new_nant) < 0)
  {
    multilog (log, LOG_ERR, "recv: failed to set NANT=%u in header\n", new_nant);
  }

  uint64_t old_bytes_per_second, new_bytes_per_second;
  if (ascii_header_get (buffer, "BYTES_PER_SECOND", "%"PRIu64"", &old_bytes_per_second) != 1)
  {
    multilog (log, LOG_WARNING, "recv: failed to read BYTES_PER_SECOND from header\n");
  }
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: old BYTES_PER_SECOND=%"PRIu64"\n", old_bytes_per_second);

  uint64_t old_obs_offset, new_obs_offset;
  if (ascii_header_get (buffer, "OBS_OFFSET", "%"PRIu64"", &old_obs_offset) != 1)
  {
    multilog (log, LOG_WARNING, "recv: failed to read OBS_OFFSET from header\n");
  }
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: old OBS_OFFSET=%"PRIu64"\n", old_obs_offset);

  uint64_t old_resolution, new_resolution;
  if (ascii_header_get (buffer, "RESOLUTION", "%"PRIu64"", &old_resolution) != 1)
  {
    multilog (log, LOG_WARNING, "recv: failed to read RESOLUTION from header\n");
  }
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: old RESOLUTION=%"PRIu64"\n", old_resolution);

  int64_t old_file_size, new_file_size;
  if (ascii_header_get (buffer, "FILE_SIZE", "%"PRIi64"", &old_file_size) != 1)
  {
    old_file_size = -1;
  }
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: old FILE_SIZE=%"PRIi64"\n", old_file_size);

  new_bytes_per_second = old_bytes_per_second * ctx->nconn;
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: setting BYTES_PER_SECOND=%"PRIu64" in header\n", new_bytes_per_second);
  if (ascii_header_set (buffer, "BYTES_PER_SECOND", "%"PRIu64"", new_bytes_per_second) < 0)
  {
    multilog (log, LOG_WARNING, "recv: failed to set BYTES_PER_SECOND=%"PRIu64" in header\n", new_bytes_per_second);
  }

  new_obs_offset = old_obs_offset * ctx->nconn;
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: setting OBS_OFFSET=%"PRIu64" in header\n", new_obs_offset);
  if (ascii_header_set (buffer, "OBS_OFFSET", "%"PRIu64"", new_obs_offset) < 0)
  {
    multilog (log, LOG_WARNING, "recv: failed to set OBS_OFFSET=%"PRIu64" in header\n", new_obs_offset);
  }

  new_resolution = old_resolution * ctx->nconn;
  if (ctx->verbose)
    multilog (log, LOG_INFO, "recv: setting RESOLUTION=%"PRIu64" in header\n", new_resolution);
  if (ascii_header_set (buffer, "RESOLUTION", "%"PRIu64"", new_resolution) < 0)
  {
    multilog (log, LOG_WARNING, "recv: failed to set RESOLUTION=%"PRIu64" in header\n", new_resolution);
  }

  if (old_file_size > 0)
  {
    new_file_size = old_file_size * ctx->nconn;
    if (ctx->verbose)
      multilog (log, LOG_INFO, "recv: setting FILE_SIZE=%"PRIi64" in header\n", new_file_size);
    if (ascii_header_set (buffer, "FILE_SIZE", "%"PRIi64"", new_file_size) < 0)
    {
      multilog (log, LOG_WARNING, "recv: failed to set FILE_SIZE=%"PRIi64" in header\n", new_file_size);
    }
  }

  // write the antennae list to the output header
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv: construct module list: nant=%d\n", new_nant);
  unsigned iant = 0;
  char module_list[112];  // 16 * 6 chars
  char full_list[2112];   // 352 * 6chars
  while (iant < new_nant)
  {
    // find the connection which contains iant
    for (i=0; i<ctx->nconn; i++)
    {
      if (iant >= ctx->conn_info[i].ant_first && iant <= ctx->conn_info[i].ant_last)
      {
        if (ascii_header_get (ctx->ib_cms[i]->header_mb->buffer, "ANTENNAE", "%s", module_list) != 1)
        {
          multilog (log, LOG_ERR, "recv: could not read ANTENNAE from header\n");
          return -1;
        }
        if (iant == 0)
        {
          strcpy(full_list, module_list);
        }
        else
        {
          strcat(full_list,","); 
          strcat(full_list,module_list);
        }

        iant += ((ctx->conn_info[i].ant_last - ctx->conn_info[i].ant_first) + 1);
      }
    }
  }

  if (ascii_header_set (buffer, "ANTENNAE", "%s", full_list) < 0)
  {
    multilog (log, LOG_ERR, "recv: failed to set ATNENNAE=%s in header\n", full_list);
    return -1;
  }

  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv: post_recv [BYTES TO XFER]\n");
  // find the connection which contains iant
  for (i=0; i<ctx->nconn; i++)
  {
    if (ctx->verbose > 1)
      multilog(ctx->log, LOG_INFO, "recv: [%d] post_recv on sync_from [BYTES TO XFER]\n", i);
    if (dada_ib_post_recv(ib_cms[i], ib_cms[i]->sync_from) < 0)
    {
      multilog(ctx->log, LOG_ERR, "recv: [%d] post_recv on sync_from [BYTES TO XFER] failed\n", i);
      return -1;
    }
  }

  // use the size of the first cms header
  return (int64_t) bytes;
}


/*! Transfers 1 datablock at a time to mopsr_ibdb */
int64_t mopsr_ibdb_recv_block (dada_client_t* client, void * buffer, 
                               uint64_t data_size, uint64_t block_id)
{
  mopsr_bf_ib_t * ctx = (mopsr_bf_ib_t*) client->context;

  dada_ib_cm_t ** ib_cms = ctx->ib_cms;

  multilog_t * log = client->log;

  if (ctx->verbose > 1)
    multilog(log, LOG_INFO, "recv_block: block_size=%"PRIu64", block_id=%"PRIu64"\n", data_size, block_id);

  unsigned int i;

  // send READY message to inform sender we are ready for DATA 
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv_block: send_messages [READY DATA]\n");
  if (dada_ib_send_messages(ib_cms, ctx->nconn, DADA_IB_READY_KEY, 0) < 0)
  {
    multilog(ctx->log, LOG_ERR, "recv_block: send_messages [READY DATA] failed\n");
    return -1;
  }

  // wait for the number of bytes to be received
  if (ctx->verbose)
        multilog(ctx->log, LOG_INFO, "recv_block: recv_messages [BYTES TO XFER]\n");
  if (dada_ib_recv_messages(ib_cms, ctx->nconn, DADA_IB_BYTES_TO_XFER_KEY) < 0)
  {
    multilog(ctx->log, LOG_ERR, "recv_block: recv_messages [BYTES TO XFER] failed\n");
    return -1;
  }

  // count the number of bytes to be received
  uint64_t bytes_to_xfer = 0;
  for (i=0; i<ctx->nconn; i++)
  {
    bytes_to_xfer += ib_cms[i]->sync_from_val[1];
    if (ctx->verbose > 1)
      multilog (ctx->log, LOG_INFO, "recv_block: [%d] bytes to be recvd=%"PRIu64"\n",
                i, ib_cms[i]->sync_from_val[1]);
  }

  // special case where we end observation on precise end of block
  if (bytes_to_xfer == 0)
  {
    //if (ctx->verbose)
      multilog(ctx->log, LOG_INFO, "recv_block: bytes_to_xfer=0, obs ended [EOD]\n");
    return 0;
  }

  // if the number of bytes to be received is less than the block size, this is the end of the observation
  if (bytes_to_xfer < data_size)
  {
    //if (ctx->verbose)
      multilog(ctx->log, LOG_INFO, "recv_block: bytes_to_xfer=%"PRIu64" < %"PRIu64", obs ending\n", bytes_to_xfer, data_size);
    ctx->obs_ending = 1;
  }

  // post recv for the number of bytes that were transferred
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv_block: post_recv [BYTES XFERRED]\n");
  for (i=0; i<ctx->nconn; i++)
  {
    if (ctx->verbose > 1)
      multilog(ctx->log, LOG_INFO, "recv_block: [%d] post_recv on sync_from [BYTES XFERRED]\n", i);
    if (dada_ib_post_recv(ib_cms[i], ib_cms[i]->sync_from) < 0)
    {
      multilog(ctx->log, LOG_ERR, "recv_block: [%d] post_recv on sync_from [BYTES XFERRED] failed\n", i);
      return -1;
    }
  }

  // send the memory address of the block_id to be filled remotely via RDMA
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv_block: send_messages [BLOCK ID]\n");
  for (i=0; i<ctx->nconn; i++)
  {
    ib_cms[i]->sync_to_val[0] = (uint64_t) ib_cms[i]->local_blocks[block_id].buf_va;
    ib_cms[i]->sync_to_val[1] = (uint64_t) ib_cms[i]->local_blocks[block_id].buf_rkey;

    uintptr_t buf_va = (uintptr_t) ib_cms[i]->sync_to_val[0];
    uint32_t buf_rkey = (uint32_t) ib_cms[i]->sync_to_val[1];
    if (ctx->verbose > 1)
      multilog(ctx->log, LOG_INFO, "recv_block: [%d] local_block_id=%"PRIu64", local_buf_va=%p, "
                         "local_buf_rkey=%p\n", i, block_id, buf_va, buf_rkey);
  }
  if (dada_ib_send_messages(ib_cms, ctx->nconn, UINT64_MAX, UINT64_MAX) < 0)
  {
    multilog(ctx->log, LOG_ERR, "recv_block: send_messages [BLOCK ID] failed\n");
    return -1;
  }

  // remote RDMA transfer is ocurring now...
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv_block: waiting for completion "
             "on block %"PRIu64"...\n", block_id);

  // wait for the number of bytes transferred
  int64_t bytes_received = 0;
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv_block: recv_messages [BYTES XFERRED]\n");
  if (dada_ib_recv_messages(ib_cms, ctx->nconn, DADA_IB_BYTES_XFERRED_KEY) < 0)
  {
    multilog(ctx->log, LOG_ERR, "recv_block: recv_messages [BYTES XFERRED] failed\n");
    return -1;
  }
  for (i=0; i<ctx->nconn; i++)
  {
    bytes_received += ib_cms[i]->sync_from_val[1];
    if (ctx->verbose > 1)
      multilog (ctx->log, LOG_INFO, "recv_block: [%d] bytes recvd=%"PRIu64"\n",
                i, ib_cms[i]->sync_from_val[1]);
  }

  // post receive for the BYTES TO XFER in next block function call
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "recv_block: post_recv [BYTES TO XFER]\n");
  for (i=0; i<ctx->nconn; i++)
  {
    if (ctx->verbose > 1)
      multilog(ctx->log, LOG_INFO, "recv_block: [%d] post_recv [BYTES TO XFER]\n", i);
    if (dada_ib_post_recv(ib_cms[i], ib_cms[i]->sync_from) < 0)
    {
      multilog(ctx->log, LOG_ERR, "recv_block: [%d] post_recv [BYTES TO XFER] failed\n", i);
      return -1;
    }
  }

  if (ctx->verbose > 1)
    multilog(ctx->log, LOG_INFO, "recv_block: bytes transferred=%"PRIi64"\n", bytes_received);

  return bytes_received;
}


/*
 * required initialization of IB device and associate verb structs
 */
int mopsr_ibdb_ib_init (mopsr_bf_ib_t * ctx, dada_hdu_t * hdu, multilog_t * log)
{
  if (ctx->verbose > 1)
    multilog (ctx->log, LOG_INFO, "mopsr_ibdb_ib_init()\n");

  // infiniband post_send size will be 
  const unsigned int ndim = 2;
  unsigned int modulo_size = ctx->nant * ndim;

  if (ctx->verbose > 1)
    multilog (ctx->log, LOG_INFO, "ib_init: nant=%u ndim=%u modulo_size=%u\n", ctx->nant, ndim, modulo_size);

  uint64_t db_nbufs = 0;
  uint64_t db_bufsz = 0;
  uint64_t hb_nbufs = 0;
  uint64_t hb_bufsz = 0;
  char ** db_buffers = 0;
  char ** hb_buffers = 0;

  if (ctx->verbose)
    multilog (ctx->log, LOG_INFO, "ib_init: getting datablock info\n");
  // get the datablock addresses for memory registration
  db_buffers = dada_hdu_db_addresses(hdu, &db_nbufs, &db_bufsz);
  hb_buffers = dada_hdu_hb_addresses(hdu, &hb_nbufs, &hb_bufsz);

  // check that the chunk size is a factor of DB size
  if (db_bufsz % modulo_size != 0)
  {
    multilog(log, LOG_ERR, "ib_init: modulo size [%d] was not a factor "
             "of data block size [%"PRIu64"]\n", modulo_size, db_bufsz);
    return -1;
  }
  uint64_t recv_depth = db_bufsz / modulo_size;

  // alloc memory for ib_cm ptrs
  if (ctx->verbose)
    multilog (ctx->log, LOG_INFO, "ib_init: mallocing ib_cms\n");
  ctx->ib_cms = (dada_ib_cm_t **) malloc(sizeof(dada_ib_cm_t *) * ctx->nconn);
  if (!ctx->ib_cms)
  {
    multilog(log, LOG_ERR, "ib_init: could not allocate memory\n");
    return -1;
  }

  // create the CM and CM channel
  unsigned i;
  for (i=0; i < ctx->nconn; i++)
  {
    ctx->ib_cms[i] = dada_ib_create_cm(db_nbufs, log);
    if (!ctx->ib_cms[i])
    {
      multilog(log, LOG_ERR, "ib_init: dada_ib_create_cm on src %d of %d  failed\n", i, ctx->nconn);
      return -1;
    }

    ctx->conn_info[i].ib_cm = ctx->ib_cms[i];

    ctx->ib_cms[i]->verbose = ctx->verbose;
    ctx->ib_cms[i]->send_depth = 1;
    ctx->ib_cms[i]->recv_depth = 1;
    ctx->ib_cms[i]->port = ctx->conn_info[i].port;
    ctx->ib_cms[i]->bufs_size = db_bufsz;
    ctx->ib_cms[i]->header_size = hb_bufsz;
    ctx->ib_cms[i]->db_buffers = db_buffers;
  }

  return 0;
}

int mopsr_ibdb_destroy (mopsr_bf_ib_t * ctx) 
{
  unsigned i=0;
  int rval = 0;
  for (i=0; i<ctx->nconn; i++)
  {
    if (ctx->verbose)
      multilog(ctx->log, LOG_INFO, "destroy: dada_ib_destroy() [%d]\n", i);
    if (dada_ib_destroy(ctx->ib_cms[i]) < 0)
    {
      multilog(ctx->log, LOG_ERR, "dada_ib_destroy for %d failed\n", i);
      rval = -1;
    }
  }
  return rval;
}

int mopsr_ibdb_open_connections (mopsr_bf_ib_t * ctx, multilog_t * log)
{
  dada_ib_cm_t ** ib_cms = ctx->ib_cms;

  mopsr_bf_conn_t * conns = ctx->conn_info;

  if (ctx->verbose > 1)
    multilog(ctx->log, LOG_INFO, "mopsr_ibdb_open_connections()\n");

  unsigned i = 0;
  int rval = 0;
  pthread_t * connections = (pthread_t *) malloc(sizeof(pthread_t) * ctx->nconn);

  // start all the connection threads
  for (i=0; i<ctx->nconn; i++)
  {
    if (!ib_cms[i]->cm_connected)
    {
      if (ctx->verbose > 1)
        multilog (ctx->log, LOG_INFO, "open_connections: mopsr_ibdb_init_thread ib_cms[%d]=%p\n",
                  i, ctx->ib_cms[i]);

      rval = pthread_create(&(connections[i]), 0, (void *) mopsr_ibdb_init_thread,
                          (void *) &(conns[i]));
      if (rval != 0)
      {
        multilog (ctx->log, LOG_INFO, "open_connections: error creating init_thread\n");
        return -1;
      }
    }
    else
    {
      multilog (ctx->log, LOG_INFO, "open_connections: ib_cms[%d] already connected\n", i);
    }
  }

  if (ctx->verbose)
    multilog (ctx->log, LOG_INFO, "open_connections: waiting for connection threads to return\n");

  // join all the connection threads
  void * result;
  int init_cm_ok = 1;
  for (i=0; i<ctx->nconn; i++)
  {
    if (ib_cms[i]->cm_connected <= 1)
    {
      if (ctx->verbose)
        multilog (ctx->log, LOG_INFO, "open_connections: joining connection thread %d\n", i);
      pthread_join (connections[i], &result);
      if (ctx->verbose)
        multilog (ctx->log, LOG_INFO, "open_connections: connection thread %d joined\n", i);
      if (!ib_cms[i]->cm_connected)
        init_cm_ok = 0;
    }

    // set to 2 to indicate connection is established
    ib_cms[i]->cm_connected = 2;
  }
  free(connections);
  if (!init_cm_ok)
  {
    multilog(ctx->log, LOG_ERR, "open_connections: failed to init CM connections\n");
    return -1;
  }

  // pre-post receive for the header transfer 
  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "open_connections: post_recv on header_mb [HEADER]\n");
  for (i=0; i<ctx->nconn; i++)
  {
    if (ctx->verbose > 1)
      multilog(ctx->log, LOG_INFO, "open_connections: [%d] post_recv on header_mb [HEADER]\n", i);

    if (dada_ib_post_recv(ib_cms[i], ib_cms[i]->header_mb) < 0)
    {
      multilog(ctx->log, LOG_ERR, "open_connections: [%d] post_recv on header_mb [HEADER] failed\n", i);
      return -1;
    }
  }

  // accept each connection
  int accept_result = 0;

  if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "open_connections: accepting connections\n");

  for (i=0; i<ctx->nconn; i++)
  {
    if (!ib_cms[i]->ib_connected)
    {
      if (ctx->verbose)
        multilog(ctx->log, LOG_INFO, "open_connections: ib_cms[%d] accept\n", i);
      if (dada_ib_accept (ib_cms[i]) < 0)
      {
        multilog(ctx->log, LOG_ERR, "open_connections: dada_ib_accept failed\n");
        accept_result = -1;
      }
      ib_cms[i]->ib_connected = 1;
    }
  }

  //if (ctx->verbose)
    multilog(ctx->log, LOG_INFO, "open_connections: connections initialized\n");

  return accept_result;
}


/*
 * Thread to open connection between sender and receivers
 */
void * mopsr_ibdb_init_thread (void * arg)
{
  mopsr_bf_conn_t * conn = (mopsr_bf_conn_t *) arg;

  dada_ib_cm_t * ib_cm = conn->ib_cm;

  multilog_t * log = ib_cm->log;

  if (ib_cm->verbose > 1)
    multilog (log, LOG_INFO, "init_thread: ib_cm=%p\n", ib_cm);

  ib_cm->cm_connected = 0;
  ib_cm->ib_connected = 0;
  ib_cm->port = conn->port;

  if (ib_cm->verbose)
    multilog(log, LOG_INFO, "init_thread: listening for CM event on port %d\n", ib_cm->port);

  // listen for a connection request on the specified port
  if (ib_cm->verbose > 1)
    multilog(log, LOG_INFO, "init_thread: dada_ib_listen_cm (port=%d)\n", ib_cm->port);

  if (dada_ib_listen_cm(ib_cm, ib_cm->port) < 0)
  {
    multilog(log, LOG_ERR, "init_thread: dada_ib_listen_cm failed\n");
    pthread_exit((void *) &(ib_cm->cm_connected));
  }

  // create the IB verb structures necessary
  if (ib_cm->verbose > 1)
    multilog(log, LOG_INFO, "init_thread: depth=%"PRIu64"\n", ib_cm->send_depth + ib_cm->recv_depth);

  if (dada_ib_create_verbs(ib_cm) < 0)
  {
    multilog(log, LOG_ERR, "init_thread: dada_ib_create_verbs failed\n");
    pthread_exit((void *) &(ib_cm->cm_connected));
  }

  int flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE;

  // register each data block buffer with as a MR within the PD
  if (dada_ib_reg_buffers(ib_cm, ib_cm->db_buffers, ib_cm->bufs_size, flags) < 0)
  {
    multilog(log, LOG_ERR, "init_thread: dada_ib_register_memory_buffers failed to %s:%d\n", conn->host, conn->port);
    pthread_exit((void *) &(ib_cm->cm_connected));
  }

  ib_cm->header = (char *) malloc(sizeof(char) * ib_cm->header_size);
  if (!ib_cm->header)
  {
    multilog(log, LOG_ERR, "init_thread: could not allocate memory for header\n");
    pthread_exit((void *) &(ib_cm->cm_connected));
  }

  if (ib_cm->verbose > 1)
    multilog(log, LOG_INFO, "init_thread: reg header_mb\n");
  ib_cm->header_mb = dada_ib_reg_buffer(ib_cm, ib_cm->header, ib_cm->header_size, flags);
  if (!ib_cm->header_mb)
  {
    multilog(log, LOG_INFO, "init_thread: reg header_mb failed\n");
    pthread_exit((void *) &(ib_cm->cm_connected));
  }

  ib_cm->header_mb->wr_id = 10000;

  if (ib_cm->verbose > 1)
    multilog(log, LOG_INFO, "init_thread: dada_ib_create_qp\n");
  if (dada_ib_create_qp (ib_cm) < 0)
  {
    multilog(log, LOG_ERR, "ib_init: dada_ib_create_qp failed\n");
    pthread_exit((void *) &(ib_cm->cm_connected));
  }

  if (ib_cm->verbose > 1)
    multilog(log, LOG_INFO, "init_thread: thread completed\n");
  ib_cm->cm_connected = 1;
  pthread_exit((void *) &(ib_cm->cm_connected));
}


/*! Simple signal handler for SIGINT */
void signal_handler(int signalValue)
{
  quit_signal = 1;
  exit(EXIT_FAILURE);
}


int main (int argc, char **argv)
{
  /* DADA Data Block to Node configuration */
  mopsr_bf_ib_t ctx = MOPSR_IB_INIT;

  /* DADA Header plus Data Unit */
  dada_hdu_t* hdu = 0;

  /* DADA Primary Read Client main loop */
  dada_client_t* client = 0;

  /* DADA Logger */
  multilog_t* log = 0;

  /* Flag set in verbose mode */
  int verbose = 0;

  /* Quit flag */
  int quit = 0;

  /* hexadecimal shared memory key */
  key_t dada_key = DADA_DEFAULT_BLOCK_KEY;

  char * cornerturn_cfg = 0;

  int channel = -1;

  int arg = 0;

  unsigned i = 0;

  while ((arg=getopt(argc,argv,"hk:sv")) != -1)
  {
    switch (arg) 
    {
      case 'h':
        usage ();
        return 0;
      
      case 'k':
        if (sscanf (optarg, "%x", &dada_key) != 1) {
          fprintf (stderr,"mopsr_ibdb: could not parse key from %s\n",optarg);
          return EXIT_FAILURE;
        }
        break;

      case 's':
        quit = 1;
        break;

      case 'v':
        verbose++;
        break;

      default:
        usage ();
        return 1;
    }
  }

  // check and parse the command line arguments
  if (argc-optind != 2) {
    fprintf(stderr, "ERROR: 2 command line arguments are required\n\n");
    usage();
    exit(EXIT_FAILURE);
  }

  channel = atoi(argv[optind]);

  cornerturn_cfg = strdup(argv[optind+1]);

  // do not use the syslog facility
  log = multilog_open ("mopsr_ibdb", 0);
  multilog_add (log, stderr);
  hdu = dada_hdu_create (log);

  dada_hdu_set_key(hdu, dada_key);

  if (dada_hdu_connect (hdu) < 0)
    return EXIT_FAILURE;

  if (dada_hdu_lock_write (hdu) < 0)
    return EXIT_FAILURE;

  client = dada_client_create ();

  client->log = log;

  client->data_block = hdu->data_block;
  client->header_block = hdu->header_block;

  client->open_function     = mopsr_ibdb_open;
  client->io_function       = mopsr_ibdb_recv;
  client->io_block_function = mopsr_ibdb_recv_block;
  client->close_function    = mopsr_ibdb_close;
  client->direction         = dada_client_writer;

  client->quiet = 1;
  client->context = &ctx;

  ctx.log = log;
  ctx.verbose = verbose;

  // handle SIGINT gracefully
  signal(SIGINT, signal_handler);

  // parse the cornerturn configuration
  if (verbose)
    multilog (log, LOG_INFO, "main: mopsr_setup_cornerturn_recv(channel=%d)\n", channel);
  ctx.conn_info = mopsr_setup_cornerturn_recv (cornerturn_cfg, &ctx, channel);
  if (!ctx.conn_info)
  {
    multilog (log, LOG_ERR, "Failed to parse cornerturn configuration file\n");
    dada_hdu_unlock_write (hdu);
    dada_hdu_disconnect (hdu);
    return EXIT_FAILURE;
  }

  // Initiase IB resources
  if (verbose)
    multilog (log, LOG_INFO, "main: mopsr_ibdb_ib_init()\n");
  if (mopsr_ibdb_ib_init (&ctx, hdu, log) < 0)
  {
    multilog (log, LOG_ERR, "Failed to initialise IB resources\n");
    dada_hdu_unlock_write (hdu);
    dada_hdu_disconnect (hdu);
    return EXIT_FAILURE;
  }

  // open IB connections with the receivers
  if (verbose)
    multilog (log, LOG_INFO, "main: mopsr_ibdb_open_connections()\n");
  if (mopsr_ibdb_open_connections (&ctx, log) < 0)
  {
    multilog (log, LOG_ERR, "Failed to open IB connections\n");
    dada_hdu_unlock_write (hdu);
    dada_hdu_disconnect (hdu);
    return EXIT_FAILURE;
  }

  while (!client->quit)
  {
    if (verbose)
      multilog (log, LOG_INFO, "dada_client_write()\n");
    if (dada_client_write (client) < 0)
    {
      multilog (log, LOG_ERR, "dada_client_write() failed\n");
      client->quit = 1;
    }

    if (verbose)
      multilog (log, LOG_INFO, "main: dada_hdu_unlock_write()\n");
    if (dada_hdu_unlock_write (hdu) < 0)
    {
      multilog (log, LOG_ERR, "could not unlock read on hdu\n");
      client->quit = 1;
    }

    if (quit || ctx.quit)
      client->quit = 1;

    if (!client->quit)
    {
      if (verbose)
        multilog (log, LOG_INFO, "main: dada_hdu_lock_write()\n");
      if (dada_hdu_lock_write (hdu) < 0)
      {
        multilog (log, LOG_ERR, "could not lock read on hdu\n");
        client->quit = 1;
        break;
      }

      // pre-post receive for the header transfer 
      if (verbose)
        multilog(log, LOG_INFO, "main: post_recv on header_mb [HEADER]\n");
      for (i=0; i<ctx.nconn; i++)
      {
        if (verbose > 1)
          multilog(log, LOG_INFO, "main: [%d] post_recv on header_mb [HEADER]\n", i);
        if (dada_ib_post_recv(ctx.ib_cms[i], ctx.ib_cms[i]->header_mb) < 0)
        {
          multilog(log, LOG_ERR, "main : [%d] post_recv on header_mb [HEADER] failed\n", i);
          client->quit = 1;
          break;
        }
      }
    }
  }

  if (verbose)
    multilog (log, LOG_INFO, "main: dada_hdu_disconnect()\n");
  if (dada_hdu_disconnect (hdu) < 0)
    return EXIT_FAILURE;

  if (verbose)
    multilog (log, LOG_INFO, "main: mopsr_ibdb_destroy()\n");
  if (mopsr_ibdb_destroy (&ctx) < 0)
  {
    multilog(log, LOG_ERR, "mopsr_ibdb_destroy failed\n");
  }

  return EXIT_SUCCESS;
}

