#include "dada_nexus.h"

#include <stdlib.h>
#include <unistd.h>

int main ()
{
  dada_nexus_t* nexus = 0;
  char* dada_config = getenv ("DADA_CONFIG");

  if (!dada_config) {
    fprintf (stderr, "Please define the DADA_CONFIG environment variable\n");
    return -1;
  }

  fprintf (stderr, "Creating DADA nexus\n");
  nexus = dada_nexus_create ();

  fprintf (stderr, "Initializing dada_nexus\n");
  if (dada_nexus_init (nexus, dada_config) < 0) {
    fprintf (stderr, "Error while configuring the DADA nexus\n");
    return -1;
  }

  fprintf (stderr, "Sleeping in main thread for 35 seconds\n");
  sleep (35);

  fprintf (stderr, "Destroying nexus\n");
  dada_nexus_destroy (nexus);

  return 0;
}