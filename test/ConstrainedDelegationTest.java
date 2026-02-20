import java.security.PrivilegedActionException;
import java.security.PrivilegedExceptionAction;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Properties;
import java.util.Set;

import javax.security.auth.Subject;
import javax.security.auth.kerberos.KerberosKey;
import javax.security.auth.kerberos.KerberosPrincipal;
import javax.security.auth.kerberos.KerberosTicket;
import javax.security.auth.login.LoginContext;

import org.ietf.jgss.GSSCredential;
import org.ietf.jgss.GSSException;
import org.ietf.jgss.GSSManager;
import org.ietf.jgss.GSSName;

import com.sun.security.jgss.ExtendedGSSCredential;

/**
 * Constrained Delegation Test for Vagrant Lab (CORP.INTERNAL)
 *
 * Tests S4U2Self + S4U2Proxy: webappuser authenticates via keytab,
 * impersonates winuser, and connects to Oracle as that user.
 *
 * Prerequisites:
 *   - webappuser has HTTP/webapp.corp.internal SPN
 *   - webappuser has constrained delegation to oracle/oracle.corp.internal
 *   - winuser exists in AD and is mapped to an Oracle DB user
 *   - DataDirect Oracle JDBC driver on classpath
 *
 * Usage:
 *   java -Dsun.security.krb5.debug=true \
 *        -Dkeytab.path=C:\Dev\tmp\vagrant-lab \
 *        -Djava.security.krb5.conf=C:\Dev\tmp\vagrant-lab\krb5.conf \
 *        -Djava.security.auth.login.config=C:\Dev\tmp\vagrant-lab\jaas.conf \
 *        ConstrainedDelegationTest
 */
public class ConstrainedDelegationTest {

    /** The AD user to impersonate (must exist in AD and be mapped in Oracle). */
    private static final String IMPERSONATE_USER = "winuser";

    /** Oracle connection target. */
    private static final String ORACLE_HOST = "oracle.corp.internal";
    private static final String ORACLE_PORT = "1521";
    private static final String ORACLE_SERVICE = "FREEPDB1";

    public static void main(String[] args) throws Exception {
        Subject serviceSubject;
        GSSCredential impersonatedCreds;

        // Step 1: Authenticate webappuser via keytab
        System.out.println("=== Step 1: Authenticating webappuser via keytab ===");
        LoginContext lc = new LoginContext("JDBC_DRIVER_CONSTRAINED_DELEGATION");
        lc.login();
        serviceSubject = lc.getSubject();

        displaySubjectInfo(serviceSubject);

        // Step 2: Impersonate the target user via S4U2Self + S4U2Proxy
        System.out.println("\n=== Step 2: Impersonating " + IMPERSONATE_USER + " ===");
        try {
            impersonatedCreds = Subject.doAs(serviceSubject,
                new PrivilegedExceptionAction<GSSCredential>() {
                    public GSSCredential run() throws Exception {
                        GSSManager manager = GSSManager.getInstance();
                        GSSCredential serviceCreds =
                            manager.createCredential(GSSCredential.INITIATE_ONLY);
                        GSSName targetUser =
                            manager.createName(IMPERSONATE_USER, GSSName.NT_USER_NAME);
                        return ((ExtendedGSSCredential) serviceCreds).impersonate(targetUser);
                    }
                });
        } catch (PrivilegedActionException pae) {
            throw pae.getException();
        }

        System.out.println("Impersonated credential: " + impersonatedCreds.getName());

        // Step 3: Connect to Oracle using the impersonated credential
        System.out.println("\n=== Step 3: Connecting to Oracle as " + IMPERSONATE_USER + " ===");
        Properties props = new Properties();
        props.put("GSSCredential", impersonatedCreds);
        props.put("ServerName", ORACLE_HOST);
        props.put("portNumber", ORACLE_PORT);
        props.put("authenticationMethod", "Kerberos");
        props.put("ServiceName", ORACLE_SERVICE);

        // required for kerberos5pre
        props.put("useConnectVersion315", "true");

        Connection con = DriverManager.getConnection("jdbc:datadirect:oracle:", props);
        printConnectionMetaData(con);
        con.close();

        System.out.println("\n=== Constrained delegation test PASSED ===");
    }

    public static void printConnectionMetaData(Connection c) throws SQLException {
        DatabaseMetaData dbmd = c.getMetaData();
        System.out.println("\n*** DRIVER AND DATABASE INFO ***");
        System.out.println("Driver version     = " + dbmd.getDriverVersion());
        System.out.println("JDBC Major version = " + dbmd.getJDBCMajorVersion());
        System.out.println("JDBC Minor version = " + dbmd.getJDBCMinorVersion());
        System.out.println("DBMS product name  = " + dbmd.getDatabaseProductName());
        System.out.println("DBMS product ver   = " + dbmd.getDatabaseProductVersion());
        System.out.println("URL                = " + dbmd.getURL());
        System.out.println("User               = " + dbmd.getUserName());
    }

    private static void displaySubjectInfo(Subject subject) {
        System.out.println("\n=== SUBJECT DEBUG INFO ===");

        System.out.println("\n Principals:");
        Set<KerberosPrincipal> principals = subject.getPrincipals(KerberosPrincipal.class);
        for (KerberosPrincipal principal : principals) {
            System.out.println("   - " + principal);
        }

        System.out.println("\n Private Credentials:");
        for (Object cred : subject.getPrivateCredentials()) {
            System.out.println("   - " + cred.getClass().getName());
            if (cred instanceof KerberosTicket) {
                printKerberosTicket((KerberosTicket) cred);
            } else if (cred instanceof KerberosKey) {
                printKerberosKey((KerberosKey) cred);
            } else if (cred instanceof GSSCredential) {
                printGSSCredential((GSSCredential) cred);
            }
        }

        System.out.println("\n Public Credentials:");
        for (Object cred : subject.getPublicCredentials()) {
            System.out.println("   - " + cred.getClass().getName());
        }

        System.out.println("\n=================================");
    }

    private static void printKerberosTicket(KerberosTicket ticket) {
        System.out.println("     Kerberos Ticket Info:");
        System.out.println("      - Client Principal: " + ticket.getClient());
        System.out.println("      - Server Principal: " + ticket.getServer());
        System.out.println("      - Start Time: " + ticket.getStartTime());
        System.out.println("      - End Time: " + ticket.getEndTime());
        System.out.println("      - Renew Until: " + ticket.getRenewTill());
        System.out.println("      - Flags: " + decodeFlags(ticket.getFlags()));
    }

    private static void printKerberosKey(KerberosKey key) {
        System.out.println("     Kerberos Key Info:");
        System.out.println("      - Principal: " + key.getPrincipal());
        System.out.println("      - Algorithm: " + key.getAlgorithm());
        System.out.println("      - Key Version: " + key.getVersionNumber());
    }

    private static void printGSSCredential(GSSCredential cred) {
        try {
            System.out.println("     GSS Credential Info:");
            System.out.println("      - Name: " + cred.getName());
            System.out.println("      - Remaining Lifetime: " + cred.getRemainingLifetime());
            System.out.println("      - Usage: " + getUsageString(cred.getUsage()));
        } catch (GSSException e) {
            System.out.println("      - Error reading GSS Credential: " + e.getMessage());
        }
    }

    private static String getUsageString(int usage) {
        switch (usage) {
            case GSSCredential.INITIATE_ONLY: return "Initiate Only";
            case GSSCredential.ACCEPT_ONLY: return "Accept Only";
            case GSSCredential.INITIATE_AND_ACCEPT: return "Initiate and Accept";
            default: return "Unknown";
        }
    }

    private static String decodeFlags(boolean[] flags) {
        String[] flagNames = {
            "RESERVED", "FORWARDABLE", "FORWARDED", "PROXIABLE", "PROXY",
            "MAY_POSTDATE", "POSTDATED", "RENEWABLE", "INITIAL", "PRE_AUTHENT",
            "HW_AUTHENT", "TRANSITED_POLICY_CHECKED", "OK_AS_DELEGATE"
        };

        StringBuilder result = new StringBuilder();
        for (int i = 0; i < flags.length && i < flagNames.length; i++) {
            if (flags[i]) {
                result.append(flagNames[i]).append(" ");
            }
        }
        return result.toString().trim();
    }
}
