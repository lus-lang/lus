#include <stdlib.h>

__attribute__((noinline)) static void leak_allocation(void) {
  volatile unsigned char *allocation = malloc(32);
  if (allocation == NULL)
    exit(2);
  allocation[0] = 0xa5;
}

int main(void) {
  leak_allocation();
  return 0;
}
