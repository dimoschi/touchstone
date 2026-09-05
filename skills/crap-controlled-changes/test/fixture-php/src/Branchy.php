<?php

namespace CrapFixture;

class Branchy
{
    public function simple(int $x): int
    {
        return $x + 1;
    }

    public function branchy(int $x): string
    {
        if ($x < 0) {
            return 'neg';
        }
        if ($x === 0) {
            return 'zero';
        }
        if ($x > 100) {
            return 'big';
        }
        return 'ok';
    }
}
