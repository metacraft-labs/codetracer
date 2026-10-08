// A Java sample.
package org.example.sample;

import java.util.*;
import java.util.stream.Collectors;

/**
 * Javadoc for the class.
 * @author someone
 */
@SuppressWarnings("unchecked")
public final class Sample<T extends Comparable<T>> implements Runnable {
    private static final int LIMIT = 0x7F;
    private final List<T> items = new ArrayList<>();
    /* A block
       comment. */
    public Sample(Collection<? extends T> source) {
        items.addAll(source);
    }

    @Override
    public void run() {
        long big = 10_000L;
        double ratio = 2.5e-3d;
        char c = '\t';
        String text = "items: " + items.size();
        if (items.size() > LIMIT || big != 0) {
            System.out.println(text + c + ratio);
        }
        var sorted = items.stream().sorted().collect(Collectors.toList());
        for (T item : sorted) {
            synchronized (this) { System.out.println(item); }
        }
    }
}
