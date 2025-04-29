#include <stdio.h>
#include <stdlib.h>

int main() {
  int *arr = malloc(100 * sizeof(int)); // Uses Zig's allocator!
  if (!arr) {
    printf("Allocation failed!\n");
    return 1;
  }
  free(arr); // Freed via Zig's allocator
  printf("Success!\n");
  return 0;
}
