<?php

use CrapFixture\Branchy;
use PHPUnit\Framework\TestCase;

class BranchyTest extends TestCase
{
    public function testSimple(): void
    {
        $this->assertSame(2, (new Branchy())->simple(1));
    }
}
