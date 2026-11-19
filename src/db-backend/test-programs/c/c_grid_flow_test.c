/* A loop that fills a 10 x 10 array: its flow mentions `grid` on each of its
   100 passes, and shows a preview of it, whose rest loads on demand. */
#include <stdio.h>

int grid[10][10];

int main(void) {
    for (int r = 0; r < 10; r++)
        for (int c = 0; c < 10; c++)
            grid[r][c] = r * 10 + c;
    printf("Last: %d\n", grid[9][9]);
    return 0;
}
