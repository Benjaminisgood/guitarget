import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;

import org.herac.tuxguitar.io.base.TGSongReaderHandle;
import org.herac.tuxguitar.io.base.TGSongWriterHandle;
import org.herac.tuxguitar.io.gtp.*;
import org.herac.tuxguitar.song.factory.TGFactory;
import org.herac.tuxguitar.song.models.*;

/** Headless adapter around the unmodified official TuxGuitar 1.6.4 readers. */
public final class LegacyToGP5 {
    private static GTPInputStream reader(String header, GTPSettings settings) {
        if (header.startsWith("FICHIER GUITARE PRO v1")) return new GP1InputStream(settings);
        if (header.startsWith("FICHIER GUITAR PRO v2")) return new GP2InputStream(settings);
        if (header.startsWith("FICHIER GUITAR PRO v3")) return new GP3InputStream(settings);
        if (header.startsWith("FICHIER GUITAR PRO v4")) return new GP4InputStream(settings);
        if (header.startsWith("FICHIER GUITAR PRO v5")) return new GP5InputStream(settings);
        throw new IllegalArgumentException("Unsupported Guitar Pro header: " + header);
    }

    private static long noteCount(TGSong song) {
        long count = 0;
        for (int t = 0; t < song.countTracks(); t++) {
            TGTrack track = song.getTrack(t);
            for (int m = 0; m < track.countMeasures(); m++) {
                TGMeasure measure = track.getMeasure(m);
                for (int b = 0; b < measure.countBeats(); b++) {
                    TGBeat beat = measure.getBeat(b);
                    for (int v = 0; v < beat.countVoices(); v++) count += beat.getVoice(v).countNotes();
                }
            }
        }
        return count;
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("input output charset required");
        Path input = Path.of(args[0]);
        Path output = Path.of(args[1]);
        if (input.toAbsolutePath().normalize().equals(output.toAbsolutePath().normalize())) {
            throw new IllegalArgumentException("Output must differ from source");
        }
        byte[] prefix;
        try (InputStream stream = Files.newInputStream(input)) { prefix = stream.readNBytes(31); }
        if (prefix.length < 2) throw new IllegalArgumentException("Truncated Guitar Pro header");
        int length = Byte.toUnsignedInt(prefix[0]);
        if (length > prefix.length - 1) throw new IllegalArgumentException("Invalid Guitar Pro header");
        String header = new String(prefix, 1, length, StandardCharsets.US_ASCII);
        GTPSettings settings = new GTPSettings();
        settings.setCharset(args[2]);
        TGFactory factory = new TGFactory();
        TGSongReaderHandle read = new TGSongReaderHandle();
        read.setFactory(factory);
        try (InputStream stream = Files.newInputStream(input)) {
            read.setInputStream(stream);
            reader(header, settings).read(read);
        }
        TGSong song = read.getSong();
        long notes = noteCount(song);
        if (song.countTracks() == 0 || song.countMeasureHeaders() == 0) {
            throw new IllegalArgumentException("Source contains no tracks or measures");
        }
        // GP5OutputStream catches its own exceptions. Detect its error output so a
        // partial GP5 is never accepted as a successful conversion.
        ByteArrayOutputStream writerErrors = new ByteArrayOutputStream();
        PrintStream oldErr = System.err;
        try (OutputStream stream = Files.newOutputStream(output, StandardOpenOption.CREATE_NEW);
             PrintStream errors = new PrintStream(writerErrors, true, StandardCharsets.UTF_8)) {
            TGSongWriterHandle write = new TGSongWriterHandle();
            write.setFactory(factory);
            write.setSong(song);
            write.setOutputStream(stream);
            System.setErr(errors);
            new GP5OutputStream(settings).write(write);
        } finally {
            System.setErr(oldErr);
        }
        if (writerErrors.size() != 0) throw new IOException(writerErrors.toString(StandardCharsets.UTF_8));
        TGSongReaderHandle reread = new TGSongReaderHandle();
        reread.setFactory(factory);
        try (InputStream stream = Files.newInputStream(output)) {
            reread.setInputStream(stream);
            new GP5InputStream(settings).read(reread);
        }
        TGSong checked = reread.getSong();
        if (checked.countTracks() != song.countTracks() ||
                checked.countMeasureHeaders() != song.countMeasureHeaders() || noteCount(checked) != notes) {
            throw new IOException("Track, measure or note counts changed during GP5 round trip");
        }
        System.out.printf("{\"tracks\":%d,\"measures\":%d,\"notes\":%d}%n",
                song.countTracks(), song.countMeasureHeaders(), notes);
    }
}
