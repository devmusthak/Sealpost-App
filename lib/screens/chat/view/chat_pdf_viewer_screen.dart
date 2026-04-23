import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

class ChatPdfViewerScreen extends StatelessWidget {
  const ChatPdfViewerScreen({super.key, required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.black,
      body: PdfViewPinch(
        controller: PdfControllerPinch(document: PdfDocument.openFile(path)),
      ),
    );
  }
}
