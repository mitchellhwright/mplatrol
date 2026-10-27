package mplatrol.e2e;

import android.util.Log;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.UiDevice;
import java.util.Arrays;
import pl.leancode.patrol.PatrolJUnitRunner;

public final class BoundaryBehavior extends PatrolDartTest {
    protected String dartFileGroup() { return "observer_test"; }

    private static final class ExemptBehavior extends PatrolDartTest {
        protected String dartFileGroup() { return "observer_test"; }
        @Override protected boolean pregrantLocation() { return false; }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void boundary(String failure) throws Exception {
        PatrolJUnitRunner runner = new PatrolJUnitRunner();
        runner.failure = failure;
        InstrumentationRegistry.instrumentation = runner;
        Throwable observed = null;
        try { new BoundaryBehavior().runDartTest("probe"); }
        catch (IllegalStateException | AssertionError error) { observed = error; }
        check(failure.isEmpty() == (observed == null), "Original outcome preserved");
        if (failure.equals("grant")) {
            check(observed.getMessage().equals(
                    "Location pre-grant failed for android.permission.ACCESS_FINE_LOCATION"),
                    "Grant failure names the permission");
        } else if (observed instanceof IllegalStateException) {
            check(observed.getMessage().equals(failure), "Original exception preserved");
        }
        checkLifecycle(runner, failure);
        checkGrants(failure);
    }

    private static void checkLifecycle(PatrolJUnitRunner runner, String failure) {
        check(runner.installedBeforeInitialize, "Install precedes normal initialization");
        check(runner.initializations == 1, "Exactly one initialization");
        boolean beforeSetup = failure.equals("initialize") || failure.equals("grant");
        check(runner.setups == (beforeSetup ? 0 : 1), "Setup count unchanged");
        if (!beforeSetup) {
            check(runner.installedBeforeSetup, "Install precedes setup");
        }
        check(!runner.diagnosticsActive, "Cleanup removes active observer");
        check(runner.diagnosticInstalls == 1, "Exactly one install");
        check(runner.diagnosticCleanups == 1, "Exactly one finally cleanup");
        check(runner.calls == (failure.isEmpty() || failure.equals("run") ? 1 : 0),
                "No additional Dart execution");
    }

    private static void checkGrants(String failure) {
        String order = "|initializations=1|setups=0";
        java.util.List<String> expected = failure.equals("initialize")
                ? java.util.List.of()
                : failure.equals("grant")
                ? java.util.List.of("pm grant com.example android.permission.ACCESS_FINE_LOCATION" + order)
                : Arrays.asList(
                        "pm grant com.example android.permission.ACCESS_FINE_LOCATION" + order,
                        "pm grant com.example android.permission.ACCESS_COARSE_LOCATION" + order);
        check(UiDevice.commands.equals(expected),
                "Location-only grant after initialize and before setup: " + UiDevice.commands);
    }

    private static void exempt() throws Exception {
        PatrolJUnitRunner runner = new PatrolJUnitRunner();
        InstrumentationRegistry.instrumentation = runner;
        new ExemptBehavior().runDartTest("probe");
        check(runner.calls == 1, "Exempt journey still runs");
        check(UiDevice.commands.isEmpty(), "Exempt journey grants nothing: " + UiDevice.commands);
    }

    private static void absent() throws Exception {
        PatrolJUnitRunner runner = new PatrolJUnitRunner();
        InstrumentationRegistry.instrumentation = runner;
        new BoundaryBehavior().runDartTest("probe");
        check(runner.calls == 1, "Absent observer preserves execution");
        check(Log.messages.stream().anyMatch(s -> s.contains("native-diagnostics-not-packaged")),
                "Absent observer explicitly reported");
    }

    public static void main(String[] args) throws Exception {
        if (args[0].equals("absent")) absent();
        else if (args[0].equals("exempt")) exempt();
        else boundary(args[0].equals("success") ? "" : args[0]);
        System.out.println("PASS " + args[0]);
    }
}
