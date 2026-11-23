import javax.xml.crypto.dsig.*;
import javax.xml.crypto.dsig.dom.DOMValidateContext;
import javax.xml.crypto.*;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.*;
import java.io.*;
import java.security.cert.*;
import java.util.*;

public class VerifyXml {
    public static void main(String[] a) throws Exception {
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        X509Certificate cert = (X509Certificate) cf.generateCertificate(new FileInputStream(a[0]));
        System.setProperty("org.jcp.xml.dsig.secureValidation", "false");
        for (int i = 1; i < a.length; i++) {
            DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
            f.setNamespaceAware(true);
            Document doc = f.newDocumentBuilder().parse(new File(a[i]));
            Element root = doc.getDocumentElement();
            Element inf = (Element) root.getFirstChild();
            inf.setIdAttribute("Id", true);
            NodeList nl = doc.getElementsByTagNameNS(XMLSignature.XMLNS, "Signature");
            DOMValidateContext ctx = new DOMValidateContext(cert.getPublicKey(), nl.item(0));
            ctx.setProperty("org.jcp.xml.dsig.secureValidation", Boolean.FALSE);
            XMLSignature sig = XMLSignatureFactory.getInstance("DOM").unmarshalXMLSignature(ctx);
            boolean ok = sig.validate(ctx);
            boolean sv = sig.getSignatureValue().validate(ctx);
            boolean ref = ((Reference) sig.getSignedInfo().getReferences().get(0)).validate(ctx);
            System.out.println(a[i] + ": " + (ok ? "ASSINATURA VALIDA" : "INVALIDA") + " (valor=" + sv + ", digest=" + ref + ")");
        }
    }
}
