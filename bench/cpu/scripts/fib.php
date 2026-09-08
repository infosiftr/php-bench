<?php
// Recursive function-call overhead.
function fib(int $n): int {
    return $n < 2 ? $n : fib($n - 1) + fib($n - 2);
}

fib(30);
