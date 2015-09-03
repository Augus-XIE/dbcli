package org.dbcli;

import com.jcraft.jsch.*;

import java.io.*;
import java.util.HashMap;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * Created by Will on 2015/9/1.
 */
public class SSHExecutor {
    public Session session;
    public String linePrefix = "";
    public String host;
    public String user;
    public int port;
    public String password;
    public String prompt;
    JSch ssh;
    ChannelShell shell;
    PipedOutputStream shellWriter;
    Printer pr;
    HashMap<Integer, Object[]> forwards;
    HashMap<String, Channel> channels;
    boolean isLogin = false;
    String lastLine;
    boolean isEnd;


    public SSHExecutor() {
    }

    public SSHExecutor(String host, int port, String user, String password, String linePrefix) throws Exception {
        connect(host, port, user, password, linePrefix);
    }

    public void output(String message, boolean newLine) {
        StringBuilder sb = new StringBuilder((linePrefix + message).length());
        if (newLine) sb.append(linePrefix);
        for (int i = 0; i < message.length(); i++) {
            char c = message.charAt(i);
            if (c == '\r') continue;
            sb.append(c);
            if (c == '\n') sb.append(linePrefix);
        }
        if (!newLine) System.out.print(sb.toString());
        else System.out.println(sb.toString());
        System.out.flush();
    }

    public void connect(String host, int port, String user, final String password, String linePrefix) throws Exception {
        try {
            ssh = new JSch();
            session = ssh.getSession(user, host, port);
            session.setPassword(password);
            session.setConfig("StrictHostKeyChecking", "no");
            session.setConfig("PreferredAuthentications", "password,publickey,keyboard-interactive");
            session.setConfig("compression.s2c", "zlib@openssh.com,zlib,none");
            session.setConfig("compression.c2s", "zlib@openssh.com,zlib,none");
            session.setConfig("compression_level", "9");
            session.setDaemonThread(true);
            session.setServerAliveInterval((int) TimeUnit.SECONDS.toMillis(10));
            session.setServerAliveCountMax(10);
            session.setTimeout(0);
            session.setInputStream(System.in);
            session.setOutputStream(System.out);
            session.connect();
            session.setUserInfo(new SSHUserInfo("jsch"));
            this.host = host;
            this.port = port;
            this.user = user;
            this.password = password;
            forwards = new HashMap<>();
            channels = new HashMap<>();
            isLogin = true;
            setLinePrefix(linePrefix);
            shell = (ChannelShell) session.openChannel("shell");
            PipedInputStream pipeIn = new PipedInputStream();
            shellWriter = new PipedOutputStream(pipeIn);
            pr = new Printer();
            pr.reset(true);
            //FileOutputStream fileOut = new FileOutputStream( outputFileName );
            shell.setInputStream(pipeIn);
            shell.setOutputStream(pr);
            shell.setEnv("TERM","xterm-old");
            shell.setPty(true);
            shell.setPtyType("vt100", 800, 60, 1400, 900);
            shell.connect();
            waitCompletion();

        } catch (Exception e) {
            //e.printStackTrace();
            throw e;
        }
    }

    public boolean isConnect() {
        return session.isConnected();
    }

    private void closeShell() {
        try {
            prompt = null;
            lastLine = null;
            pr.close();
            shellWriter.close();
            shell.getInputStream().close();
            shell.disconnect();
        } catch (Exception e) {
        }
    }

    public void testConnect() throws Exception {
        if (isConnect() || !isLogin) return;
        {
            output("Connection is lost, try to re-connect ...", true);
            closeShell();
        }
        connect(this.host, this.port, this.user, this.password, this.linePrefix);
    }

    public void close() throws Exception {
        closeShell();
        session.disconnect();
        isLogin = false;
    }


    public void setLinePrefix(String linePrefix) {
        this.linePrefix = linePrefix == null ? "" : linePrefix;
    }

    public int setForward(int localPort, Integer remotePort, String remoteHost) throws Exception {
        testConnect();
        if (forwards.containsKey(localPort)) {
            session.delPortForwardingL(localPort);
            forwards.remove(localPort);
        }
        if (remotePort == null) return -1;
        int assignPort = session.setPortForwardingL(localPort, remoteHost == null ? host : remoteHost, remotePort);
        forwards.put(assignPort, new Object[]{remotePort, remoteHost == null ? host : remoteHost});
        return assignPort;
    }

    protected Channel getChannel(String channelType) throws Exception {
        String type = channelType.intern();
        if (channels.containsKey(type) && channels.get(type).isConnected()) return channels.get(type);
        Channel channel = session.openChannel(type);
        channels.put(type, channel);
        return channel;
    }

    public void waitCompletion() throws Exception {
        while (!isEnd) {
            int ch = Console.in.read(100L);
            while (ch > 0) {
                shellWriter.write(ch);
                pr.flush();
                ch = Console.in.read(5L);
            }
        }
        prompt = pr.getPrompt();
    }

    public String getLastLine(String[] commands, boolean isWait) throws Exception {
        pr.reset(true);
        lastLine=null;
        for (String command : commands) shellWriter.write(command.getBytes());
        if (isWait) waitCompletion();
        else pr.flush();
        return lastLine;
    }

    public void exec(String command) throws Exception {
        pr.reset(false);
        shellWriter.write(command.getBytes());
        waitCompletion();
    }

    public void sendKey(char c) throws Exception {
        if (isEnd) return;
        shellWriter.write((byte) c);
        shellWriter.flush();
    }

    public void exec_single_command(String command) throws Exception {
        ChannelExec channel = (ChannelExec) getChannel("exec");
        channel.setCommand(command);
        channel.setInputStream(null);
        channel.setErrStream(null);
        channel.setPty(true);
        channel.setPtyType("vt102", 800, 60, 1400, 900);
        InputStream in = channel.getInputStream();
        channel.connect();

        byte[] tmp = new byte[1024];
        boolean flag = false;
        while (true) {
            while (in.available() > 0) {
                int i = in.read(tmp, 0, 1024);
                if (i < 0) break;
                output((flag == false ? this.linePrefix : "") + new String(tmp, 0, i), false);
                flag = true;
            }
            if (channel.isClosed()) {
                if (in.available() > 0) continue;
                break;
            }
            try {
                Thread.sleep(300);
            } catch (Exception ee) {
            }
        }
        output("", true);
        System.err.flush();
    }

    class SSHUserInfo implements UserInfo {

        private String passphrase = null;

        public SSHUserInfo(String passphrase) {
            super();
            this.passphrase = passphrase;
        }

        public String getPassphrase() {
            return passphrase;
        }

        public String getPassword() {
            return null;
        }

        public boolean promptPassphrase(String pass) {
            return false;
        }

        public boolean promptPassword(String pass) {
            return true;
        }

        public boolean promptYesNo(String arg0) {
            return false;
        }

        public void showMessage(String m) {
            output(m, true);
        }
    }

    class Printer extends OutputStream {
        StringBuilder sb;
        PrintWriter printer = new PrintWriter(Console.writer);
        char lastChar;
        boolean isStart;

        boolean ignoreMessage;
        Pattern p = Pattern.compile("\33\\[[\\d;]+[mK]");

        public Printer() {
            reset(false);
        }

        @Override
        public void write(int i) throws IOException {
            char c = (char) i;
            try {
                if (c == '\r' && (lastChar == '\n' || lastChar == '\r')) return;
                if (c == '\n') {
                    lastLine = p.matcher(sb.toString()).replaceAll("");
                    if (!isStart && !ignoreMessage) {//skip the first line
                        printer.println(lastLine);
                        printer.flush();
                    }
                    isStart = false;
                    sb.setLength(0);
                    return;
                }
                isEnd = (lastChar == '$' || lastChar == '>' || lastChar == '#') && c == ' ';
                sb.append(c);
            } finally {
                lastChar = c;
            }
        }

        public String getPrompt() {
            return sb.toString()==""?null:sb.toString();
        }

        public void reset(boolean ignoreMessage) {
            sb = new StringBuilder(linePrefix);
            lastChar = '\0';
            isEnd = false;
            isStart = true;
            this.ignoreMessage = ignoreMessage;
            lastLine = null;
        }

        @Override
        public synchronized void flush() {
            if(isStart || isEnd || sb==null) return;
            lastLine =p.matcher(sb.toString()).replaceAll("");
            printer.print(lastLine);
            printer.flush();
            isStart = false;
            sb.setLength(0);
        }

        @Override
        public void close() {
            //printer.close();
        }
    }
}