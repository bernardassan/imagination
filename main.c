#include <stdio.h>
#include <stdlib.h>

extern void checkLeaks();
int main() {
  int *arr = malloc(100 * sizeof(int)); // Uses Zig-tracked allocator
  if (!arr) {
    printf("Allocation failed!\n");
    return 1;
  }
  arr[0] = 42;
  printf("Allocated: %d\n", arr[0]);

  int *new_arr = realloc(arr, 200 * sizeof(int)); // Resize safely
  free(new_arr); // Correctly freed via Zig's allocator

  // void *ptr;
  // // Allocate 64B-aligned memory for AVX-512
  // if (posix_memalign(&ptr, 64, 1024) != 0) {
  //   perror("posix_memalign failed");
  //   return 1;
  // }
  // printf("Allocated 64-byte-aligned memory at %p\n", ptr);
  // free(ptr);

  // Optional: Call Zig's cleanup (if linked)
  checkLeaks(); // Checks for leaks
  printf("Success!\n");
  return 0;
}
