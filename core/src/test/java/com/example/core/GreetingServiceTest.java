package com.example.core;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

public class GreetingServiceTest {

    @Test
    void greet_returnsFormattedMessage() {
        assertEquals("Hello, World!", new GreetingService().greet("World"));
    }
}
