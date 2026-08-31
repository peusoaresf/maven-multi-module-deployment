package com.example.scheduler;

import com.example.core.GreetingService;

public class Scheduler {
    private static final GreetingService greetingService = new GreetingService();

    public static void main(String[] args) {
        greetingService.greet("Pedro");
    }
}
