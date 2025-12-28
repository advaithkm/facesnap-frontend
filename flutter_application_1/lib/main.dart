// main.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'package:http_parser/http_parser.dart' as http_parser; // Needed for contentType
import 'package:image_picker/image_picker.dart';
import './signUp.dart';
// Initialize app
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://ewxtinumbrzmfmepvlrv.supabase.co',
    anonKey: '',
  );

  // Initialize camera
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => AttendanceProvider()),
      ],
      child: MyApp(camera: firstCamera),
    ),
  );
}

class MyApp extends StatelessWidget {
  final CameraDescription camera;

  const MyApp({Key? key, required this.camera}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Attendance',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
        routes: {
          '/signup': (context) => const SignupSelectionPage(),
        },
      home: Consumer<AuthProvider>(
        builder: (context, authProvider, _) {
          if (authProvider.isLoading) {
            return const SplashScreen();
          } else if (authProvider.isLoggedIn) {
            if (authProvider.isTeacher) {
              return TeacherDashboard(camera: camera);
            } else {
              return StudentDashboard();
            }
          } else {
            return LoginScreen();
          }
        },
      ),
    );
  }
}

// Provider for authentication state
class AuthProvider extends ChangeNotifier {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  bool _isTeacher = false;
  Map<String, dynamic>? _userData;

  bool get isLoading => _isLoading;
  bool get isLoggedIn => _isLoggedIn;
  bool get isTeacher => _isTeacher;
  Map<String, dynamic>? get userData => _userData;

  AuthProvider() {
    _checkCurrentUser();
  }

  Future<void> _checkCurrentUser() async {
    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;

    if (session != null) {
      // Determine if user is a teacher or student
      final email = session.user.email;

      if (email != null) {
        final teacherResponse = await supabase
            .from('teachers')
            .select()
            .eq('email', email)
            .maybeSingle();

        if (teacherResponse != null) {
          _isTeacher = true;
          _userData = teacherResponse;
        } else {
          final studentResponse = await supabase
              .from('students')
              .select()
              .eq('email', email)
              .maybeSingle();

          if (studentResponse != null) {
            _userData = studentResponse;
          }
        }

        _isLoggedIn = true;
      }
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> login(String email, String password, bool isTeacher) async {
    _isLoading = true;
    notifyListeners();

    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      _isTeacher = isTeacher;

      if (isTeacher) {
        final teacherResponse = await supabase
            .from('teachers')
            .select()
            .eq('email', email)
            .single();

        _userData = teacherResponse;
      } else {
        final studentResponse = await supabase
            .from('students')
            .select()
            .eq('email', email)
            .single();

        _userData = studentResponse;
      }

      _isLoggedIn = true;
    } catch (e) {
      debugPrint('Error during login: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.signOut();

      _isLoggedIn = false;
      _isTeacher = false;
      _userData = null;
    } catch (e) {
      debugPrint('Error during logout: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

// Provider for attendance state
class AttendanceProvider extends ChangeNotifier {
  List<Map<String, dynamic>> _courses = [];
  List<Map<String, dynamic>> _students = [];
  Map<String, dynamic>? _currentSession;
  bool _isSessionActive = false;
  bool _isProcessing = false;
  List<Map<String, dynamic>> _attendanceRecords = [];

  List<Map<String, dynamic>> get courses => _courses;
  List<Map<String, dynamic>> get students => _students;
  Map<String, dynamic>? get currentSession => _currentSession;
  bool get isSessionActive => _isSessionActive;
  bool get isProcessing => _isProcessing;
  List<Map<String, dynamic>> get attendanceRecords => _attendanceRecords;

  Future<void> loadCourses(int teacherId) async {
    try {
      final supabase = Supabase.instance.client;
      final schedules = await supabase
          .from('class_schedules')
          .select('course_id, courses(*)')
          .eq('teacher_id', teacherId);

      final uniqueCourses = <String, Map<String, dynamic>>{};

      for (final schedule in schedules) {
        final courseId = schedule['course_id'];
        final course = schedule['courses'];
        uniqueCourses[courseId] = course;
      }
      if (uniqueCourses.isEmpty) {
        final coursesList = await supabase
            .from('courses')
            .select()
            .limit(20);

        for (final course in coursesList) {
          uniqueCourses[course['course_id']] = course;
        }
      }
      _courses = uniqueCourses.values.toList();
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading courses: $e');
    }
  }

  Future<void> loadStudentsByCourse(String courseId, String branch) async {
    try {
      final supabase = Supabase.instance.client;
      final students = await supabase
          .from('students')
          .select()
          .eq('branch', branch);

      _students = List<Map<String, dynamic>>.from(students);
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading students: $e');
    }
  }

  Future<void> startAttendanceSession(String courseId, int teacherId) async {
    _isProcessing = true;
    notifyListeners();

    try {
      final supabase = Supabase.instance.client;
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final now = DateFormat('HH:mm:ss').format(DateTime.now());

      final session = await supabase
          .from('attendance_sessions')
          .insert({
        'course_id': courseId,
        'teacher_id': teacherId,
        'date': today,
        'start_time': now,
        'status': 'active'
      })
          .select()
          .single();

      _currentSession = session;
      _isSessionActive = true;
      _attendanceRecords = [];
    } catch (e) {
      debugPrint('Error starting attendance session: $e');
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> endAttendanceSession() async {
    if (_currentSession == null) return;

    _isProcessing = true;
    notifyListeners();

    try {
      final supabase = Supabase.instance.client;
      final now = DateFormat('HH:mm:ss').format(DateTime.now());

      await supabase
          .from('attendance_sessions')
          .update({
        'end_time': now,
        'status': 'completed'
      })
          .eq('session_id', _currentSession!['session_id']);

      _currentSession = null;
      _isSessionActive = false;
    } catch (e) {
      debugPrint('Error ending attendance session: $e');
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> markAttendance(int studentId, String status) async {
    if (_currentSession == null) return;

    try {
      final supabase = Supabase.instance.client;
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final now = DateFormat('HH:mm:ss').format(DateTime.now());

      // First check if attendance for this student is already recorded for today's session
      final existingRecord = await supabase
          .from('attendance_records')
          .select()
          .eq('session_id', _currentSession!['session_id'])
          .eq('student_id', studentId)
          .maybeSingle();

      if (existingRecord == null) {
        // Insert new attendance record
        await supabase
            .from('attendance_records')
            .insert({
          'session_id': _currentSession!['session_id'],
          'course_id': _currentSession!['course_id'],
          'student_id': studentId,
          'teacher_id': _currentSession!['teacher_id'],
          'date': today,
          'time': now,
          'status': status
        })
            .select()
            .single();

        // Add to local list for UI updates
        _attendanceRecords.add({
          'student_id': studentId,
          'status': status,
          'timestamp': DateTime.now().toIso8601String()
        });

        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error marking attendance: $e');
    }
  }

  // Method to process attendance from the facial recognition API response
  Future<List<Map<String, dynamic>>> processDetectedFaces(List<dynamic> detectedFaces) async {
    if (!_isSessionActive || _currentSession == null) return [];

    _isProcessing = true;
    notifyListeners();

    final markedStudents = <Map<String, dynamic>>[];

    try {
      for (final face in detectedFaces) {
        // Only process faces that are identified (not "Unknown") and have high confidence
        if (face['person_name'] != "Unknown" && face['confidence'] > 0.80) {
          // Extract student ID from person_name (assuming format like "student_123")
          final personName = face['person_name'];
          final parts = personName.split('_');

          // Make sure we have at least 2 parts and the last part is numeric
          if (parts.length >= 2) {
            final studentId = int.tryParse(parts.last);
            if (studentId != null) {
              // Mark this student as present
              await markAttendance(studentId, 'present');

              markedStudents.add({
                'student_id': studentId,
                'face_data': face,
                'status': 'present'
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error processing detected faces: $e');
    } finally {
      _isProcessing = false;
      notifyListeners();
    }

    return markedStudents;
  }

  Future<List<Map<String, dynamic>>> getAttendanceReportForCourse(String courseId) async {
    try {
      final supabase = Supabase.instance.client;

      final records = await supabase
          .from('attendance_records')
          .select('*, students(first_name, last_name, email)')
          .eq('course_id', courseId)
          .order('date', ascending: false);

      return List<Map<String, dynamic>>.from(records);
    } catch (e) {
      debugPrint('Error getting attendance report: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> getStudentAttendanceStats(int studentId) async {
    try {
      final supabase = Supabase.instance.client;

      final records = await supabase
          .from('attendance_records')
          .select('course_id, status')
          .eq('student_id', studentId);

      final stats = <String, Map<String, dynamic>>{};

      for (final record in records) {
        final courseId = record['course_id'];
        final status = record['status'];

        if (!stats.containsKey(courseId)) {
          stats[courseId] = {
            'present': 0,
            'absent': 0,
            'late': 0,
            'total': 0
          };
        }

        stats[courseId]![status] = (stats[courseId]![status] ?? 0) + 1;
        stats[courseId]!['total'] = (stats[courseId]!['total'] ?? 0) + 1;
      }

      return {
        'courses': stats
      };
    } catch (e) {
      debugPrint('Error getting student attendance stats: $e');
      return {};
    }
  }
}
// Splash Screen
class SplashScreen extends StatelessWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Face Attendance',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 20),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

// Login Screen
class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isTeacher = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Face Attendance',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter your email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter your password';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Switch(
                        value: _isTeacher,
                        onChanged: (value) {
                          setState(() {
                            _isTeacher = value;
                          });
                        },
                      ),
                      Text(_isTeacher ? 'Teacher' : 'Student'),
                    ],
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () {
                      if (_formKey.currentState!.validate()) {
                        final email = _emailController.text.trim();
                        final password = _passwordController.text;

                        Provider.of<AuthProvider>(context, listen: false)
                            .login(email, password, _isTeacher);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Login', style: TextStyle(fontSize: 16)),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pushNamed(context, '/signup');
                    },
                    child: const Text('Don\'t have an account? Sign up'),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}

// Teacher Dashboard
class TeacherDashboard extends StatefulWidget {
  final CameraDescription camera;

  const TeacherDashboard({Key? key, required this.camera}) : super(key: key);

  @override
  _TeacherDashboardState createState() => _TeacherDashboardState();
}

// First, add the image_picker package to your pubspec.yaml
// dependencies:
//   image_picker: ^0.8.7+5

// At the top of your file, add this import:

// Then modify the TeacherDashboard class:
class AttendanceReportPage extends StatefulWidget {
  final String courseId;
  final String courseName;

  const AttendanceReportPage({
    Key? key,
    required this.courseId,
    required this.courseName,
  }) : super(key: key);

  @override
  _AttendanceReportPageState createState() => _AttendanceReportPageState();
}

class _AttendanceReportPageState extends State<AttendanceReportPage> {
  List<Map<String, dynamic>> _attendanceRecords = [];
  bool _isLoading = true;
  String _selectedDate = 'All';
  List<String> _availableDates = ['All'];

  @override
  void initState() {
    super.initState();
    _loadAttendanceData();
  }

  Future<void> _loadAttendanceData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final supabase = Supabase.instance.client;

      // Load attendance records for this course
      final records = await supabase
          .from('attendance_records')
          .select('*, students(*)')
          .eq('course_id', widget.courseId)
          .order('date', ascending: false);

      _attendanceRecords = List<Map<String, dynamic>>.from(records);

      // Extract unique dates for filtering
      final dates = _attendanceRecords
          .map((record) => record['date'] as String)
          .toSet()
          .toList();
      dates.sort((a, b) => b.compareTo(a)); // Sort dates in descending order

      setState(() {
        _availableDates = ['All', ...dates];
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading attendance data: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _getFilteredRecords() {
    if (_selectedDate == 'All') {
      return _attendanceRecords;
    } else {
      return _attendanceRecords.where((record) => record['date'] == _selectedDate).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredRecords = _getFilteredRecords();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.courseName} Attendance'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Text('Filter by Date: '),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedDate,
                    items: _availableDates.map((date) {
                      return DropdownMenuItem<String>(
                        value: date,
                        child: Text(date),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedDate = value!;
                      });
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: filteredRecords.isEmpty
                ? const Center(child: Text('No attendance records found'))
                : ListView.builder(
              itemCount: filteredRecords.length,
              itemBuilder: (context, index) {
                final record = filteredRecords[index];
                final student = record['students'];
                final status = record['status'];

                // Extract name from email
                final String email = student['email'] ?? '';
                final String displayName = email;

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: status == 'present'
                          ? Colors.green
                          : status == 'late'
                          ? Colors.orange
                          : Colors.red,
                      child: Icon(
                        status == 'present'
                            ? Icons.check
                            : status == 'late'
                            ? Icons.access_time
                            : Icons.close,
                        color: Colors.white,
                      ),
                    ),
                    title: Text(displayName),
                    subtitle: Text('ID: ${student['student_id']} • ${record['date']}'),
                    trailing: Text(
                      status,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: status == 'present'
                            ? Colors.green
                            : status == 'late'
                            ? Colors.orange
                            : Colors.red,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: _selectedDate != 'All'
                ? _buildAttendanceSummary(filteredRecords)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceSummary(List<Map<String, dynamic>> records) {
    int presentCount = 0;
    int absentCount = 0;
    int lateCount = 0;

    for (final record in records) {
      switch (record['status']) {
        case 'present':
          presentCount++;
          break;
        case 'absent':
          absentCount++;
          break;
        case 'late':
          lateCount++;
          break;
      }
    }

    final total = presentCount + absentCount + lateCount;
    final presentPercent = total > 0 ? (presentCount / total * 100).toStringAsFixed(1) : '0.0';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Summary for $_selectedDate',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Total Students: $total'),
            const SizedBox(height: 4),
            Text('Present: $presentCount ($presentPercent%)'),
            Text('Absent: $absentCount'),
            Text('Late: $lateCount'),
          ],
        ),
      ),
    );
  }
}

// Add this method to TeacherDashboard class to view attendance reports
void _viewAttendanceReport(BuildContext context, String courseId, String courseName) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => AttendanceReportPage(
        courseId: courseId,
        courseName: courseName,
      ),
    ),
  );
}
class _TeacherDashboardState extends State<TeacherDashboard> {
  CameraController? _cameraController;
  Future<void>? _initializeControllerFuture;
  String? _selectedCourse;
  Map<String, dynamic>? userData;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    userData = Provider
        .of<AuthProvider>(context, listen: false)
        .userData;

    if (userData != null) {
      final teacherId = userData!['teacher_id'];
      Provider.of<AttendanceProvider>(context, listen: false).loadCourses(
          teacherId);
    }
  }

  void _initializeCamera() {
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
    );
    _initializeControllerFuture = _cameraController!.initialize();
  }

  void _disposeCamera() {
    _cameraController?.dispose();
    _cameraController = null;
    _initializeControllerFuture = null;
  }

  @override
  void dispose() {
    _disposeCamera();
    super.dispose();
  }

  Future<void> _startAttendanceSession() async {
    if (_selectedCourse == null || userData == null) return;

    final attendanceProvider = Provider.of<AttendanceProvider>(
        context, listen: false);
    final teacherId = userData!['teacher_id'];

    await attendanceProvider.startAttendanceSession(
        _selectedCourse!, teacherId);

    if (attendanceProvider.isSessionActive) {
      _initializeCamera();
    }
  }

  Future<void> _endAttendanceSession() async {
    await Provider.of<AttendanceProvider>(context, listen: false)
        .endAttendanceSession();
    _disposeCamera();
  }

  // New method to handle image upload
  Future<void> _uploadImage() async {
    final attendanceProvider = Provider.of<AttendanceProvider>(context, listen: false);

    if (!attendanceProvider.isSessionActive) return;

    try {
      // Pick an image from gallery
      final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);

      if (pickedFile == null) {
        // User canceled the picker
        return;
      }

      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("Processing image...")
              ],
            ),
          );
        },
      );

      // Read image bytes
      final bytes = await pickedFile.readAsBytes();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://6045-2401-4900-1cde-b66f-7419-9570-bef7-bcbb.ngrok-free.app/detect_and_identify'),
      );

      request.files.add(http.MultipartFile.fromBytes(
        'image',
        bytes,
        filename: 'uploaded_image.jpg',
        contentType: http_parser.MediaType('image', 'jpeg'),
      ));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      // Close loading dialog
      Navigator.of(context).pop();

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final detectedFaces = responseData['detected_faces'];

        // Show results dialog
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Detected Faces'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: detectedFaces.length,
                  itemBuilder: (context, index) {
                    final face = detectedFaces[index];
                    final String personName = face['person_name'];
                    final bool isIdentified = personName != "Unknown" && face['confidence'] > 0.80;

                    // Extract student ID if available
                    int? studentId;
                    if (isIdentified && personName.contains('_')) {
                      try {
                        studentId = int.parse(personName.split('_').last);
                      } catch (e) {
                        // Handle parsing error
                      }
                    }

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: NetworkImage(
                          'https://abc3-2401-4900-1cde-b66f-25b7-f537-632d-ce8c.ngrok-free.app/${face['cropped_face']}',
                        ),
                      ),
                      title: Text(personName),
                      subtitle: Text(
                        'Confidence: ${(face['confidence'] * 100).toStringAsFixed(1)}%\n'
                            'Score: ${face['dissimilarity_score']}',
                      ),
                      trailing: studentId != null ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.check_circle, color: Colors.green),
                            onPressed: () {
                              attendanceProvider.markAttendance(studentId!, 'present');
                              Navigator.of(context).pop();
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text('Success'),
                                  content: Text('Student marked as present'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      child: Text('OK'),
                                    ),
                                  ],
                                ),
                              );
                            },
                            tooltip: 'Mark Present',
                          ),
                          IconButton(
                            icon: Icon(Icons.cancel, color: Colors.red),
                            onPressed: () {
                              attendanceProvider.markAttendance(studentId!, 'absent');
                              Navigator.of(context).pop();
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text('Success'),
                                  content: Text('Student marked as absent'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      child: Text('OK'),
                                    ),
                                  ],
                                ),
                              );
                            },
                            tooltip: 'Mark Absent',
                          ),
                        ],
                      ) : Icon(
                        isIdentified ? Icons.check_circle : Icons.question_mark,
                        color: isIdentified ? Colors.green : Colors.orange,
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    final markedStudents = await attendanceProvider.processDetectedFaces(detectedFaces);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${markedStudents.length} student(s) marked present'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  },
                  child: const Text('Auto-Mark All Present'),
                ),
              ],
            );
          },
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to detect faces: ${response.body}")),
        );
      }
    } catch (e) {
      // Make sure to close loading dialog if there's an error
      if (Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error uploading image: $e')),
      );
    }
  }


  Future<void> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;

    final attendanceProvider = Provider.of<AttendanceProvider>(
        context, listen: false);

    if (!attendanceProvider.isSessionActive) return;

    try {
      await _initializeControllerFuture;

      final xFile = await _cameraController!.takePicture();

      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("Processing image...")
              ],
            ),
          );


        },
      );

      // Read image bytes
      final bytes = await xFile.readAsBytes();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
            'https://6045-2401-4900-1cde-b66f-7419-9570-bef7-bcbb.ngrok-free.app/detect_and_identify'),
      );

      request.files.add(http.MultipartFile.fromBytes(
        'image',
        bytes,
        filename: 'captured_image.jpg',
        contentType: http_parser.MediaType('image', 'jpeg'),
      ));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      // Close loading dialog
      Navigator.of(context).pop();

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final detectedFaces = responseData['detected_faces'];

        // Show results dialog
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Detected Faces'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: detectedFaces.length,
                  itemBuilder: (context, index) {
                    final face = detectedFaces[index];
                    final String personName = face['person_name'];
                    final bool isIdentified = personName != "Unknown" &&
                        face['confidence'] > 0.80;

                    // Extract student ID if available
                    int? studentId;
                    if (isIdentified && personName.contains('_')) {
                      try {
                        studentId = int.parse(personName
                            .split('_')
                            .last);
                      } catch (e) {
                        // Handle parsing error
                      }
                    }

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: NetworkImage(
                          'https://abc3-2401-4900-1cde-b66f-25b7-f537-632d-ce8c.ngrok-free.app/${face['cropped_face']}',
                        ),
                      ),
                      title: Text(personName),
                      subtitle: Text(
                        'Confidence: ${(face['confidence'] * 100)
                            .toStringAsFixed(1)}%\n'
                            'Score: ${face['dissimilarity_score']}',
                      ),
                      trailing: studentId != null ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.check_circle, color: Colors.green),
                            onPressed: () {
                              attendanceProvider.markAttendance(
                                  studentId!, 'present');
                              Navigator.of(context).pop();
                              showDialog(
                                context: context,
                                builder: (context) =>
                                    AlertDialog(
                                      title: Text('Success'),
                                      content: Text(
                                          'Student marked as present'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child: Text('OK'),
                                        ),
                                      ],
                                    ),
                              );
                            },
                            tooltip: 'Mark Present',
                          ),
                          IconButton(
                            icon: Icon(Icons.cancel, color: Colors.red),
                            onPressed: () {
                              attendanceProvider.markAttendance(
                                  studentId!, 'absent');
                              Navigator.of(context).pop();
                              showDialog(
                                context: context,
                                builder: (context) =>
                                    AlertDialog(
                                      title: Text('Success'),
                                      content: Text('Student marked as absent'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child: Text('OK'),
                                        ),
                                      ],
                                    ),
                              );
                            },
                            tooltip: 'Mark Absent',
                          ),
                        ],
                      ) : Icon(
                        isIdentified ? Icons.check_circle : Icons.question_mark,
                        color: isIdentified ? Colors.green : Colors.orange,
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    final markedStudents = await attendanceProvider
                        .processDetectedFaces(detectedFaces);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${markedStudents
                            .length} student(s) marked present'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  },
                  child: const Text('Auto-Mark All Present'),
                ),
              ],
            );
          },
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to detect faces: ${response.body}")),
        );
      }
    } catch (e) {
      // Make sure to close loading dialog if there's an error
      if (Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final attendanceProvider = Provider.of<AttendanceProvider>(context);
    final courses = attendanceProvider.courses;
    final isSessionActive = attendanceProvider.isSessionActive;
    final attendanceRecords = attendanceProvider.attendanceRecords;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Teacher Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              Provider.of<AuthProvider>(context, listen: false).logout();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, ${
                      userData?['email'] ?? 'Teacher'}',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('College: ${userData?['college'] ?? ''}'),
                Text('Branch: ${userData?['branch'] ?? ''}'),
              ],
            ),
          ),
          const Divider(),

          // Add Attendance Reports section
          if (!isSessionActive && courses.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'View Attendance Reports:',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8.0,
                    runSpacing: 8.0,
                    children: courses.map((course) {
                      return ElevatedButton(
                        onPressed: () =>
                            _viewAttendanceReport(
                              context,
                              course['course_id'],
                              course['course_name'],
                            ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          foregroundColor: Colors.white,
                        ),
                        child: Text(course['course_name']),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const Divider(),
          ],

          if (!isSessionActive) ...[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Select Course to Take Attendance:',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    value: _selectedCourse,
                    hint: const Text('Select Course'),
                    items: courses.map((course) {
                      return DropdownMenuItem<String>(
                        value: course['course_id'],
                        child: Text(
                            '${course['course_name']} (${course['course_id']})'),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedCourse = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _selectedCourse != null
                        ? _startAttendanceSession
                        : null,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Start Attendance Session'),
                  ),
                ],
              ),
            ),
          ] else
            ...[
              Expanded(
                child: Column(
                  children: [
                    if (_initializeControllerFuture != null)
                      Expanded(
                        flex: 3,
                        child: FutureBuilder<void>(
                          future: _initializeControllerFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.done) {
                              return CameraPreview(_cameraController!);
                            } else {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                          },
                        ),
                      ),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: _takePicture,
                                  icon: const Icon(Icons.camera_alt),
                                  label: const Text('Take Photo'),
                                ),
                                ElevatedButton.icon(
                                  onPressed: _uploadImage,
                                  icon: const Icon(Icons.upload_file),
                                  label: const Text('Upload Image'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.indigo,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                                ElevatedButton.icon(
                                  onPressed: _endAttendanceSession,
                                  icon: const Icon(Icons.stop),
                                  label: const Text('End Session'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Card(
                              margin: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: Text(
                                      'Recently Marked Attendance:',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  Expanded(
                                    child: attendanceRecords.isEmpty
                                        ? const Center(
                                      child: Text('No attendance records yet'),
                                    )
                                        : ListView.builder(
                                      itemCount: attendanceRecords.length,
                                      itemBuilder: (context, index) {
                                        final record = attendanceRecords[index];
                                        return ListTile(
                                          leading: CircleAvatar(
                                            child: Text(record['student_id']
                                                .toString()),
                                          ),
                                          title: Text(
                                              'Student ID: ${record['student_id']}'),
                                          subtitle: Text(
                                              'Status: ${record['status']}'),
                                          trailing: Text(
                                            DateFormat('HH:mm:ss').format(
                                              DateTime.parse(
                                                  record['timestamp']),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

  class StudentDashboard extends StatefulWidget {
  const StudentDashboard({Key? key}) : super(key: key);

  @override
  _StudentDashboardState createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  List<Map<String, dynamic>> _attendanceHistory = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadAttendanceHistory();
  }

  Future<void> _loadAttendanceHistory() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final userData = Provider.of<AuthProvider>(context, listen: false).userData;

      if (userData != null) {
        final studentId = userData['student_id'];
        final supabase = Supabase.instance.client;

        // Use the unified attendance_records table
        final attendanceData = await supabase
            .from('attendance_records')
            .select('*, courses(*)')
            .eq('student_id', studentId)
            .order('date', ascending: false)
            .limit(30);

        setState(() {
          _attendanceHistory = List<Map<String, dynamic>>.from(attendanceData);
        });
      }
    } catch (e) {
      debugPrint('Error loading attendance history: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final userData = Provider.of<AuthProvider>(context).userData;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Student Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            onPressed: () {
              if (userData != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AttendanceStatsPage(
                      studentId: userData['student_id'],
                    ),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              Provider.of<AuthProvider>(context, listen: false).logout();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundImage: userData?['profile_photo_url'] != null
                      ? NetworkImage(userData!['profile_photo_url'])
                      : null,
                  child: userData?['profile_photo_url'] == null
                      ? const Icon(Icons.person, size: 36)
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Welcome, ${userData?['first_name'] ?? userData?['email'] ?? 'Student'}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text('Student ID: ${userData?['student_id'] ?? ''}'),
                      Text('College: ${userData?['college'] ?? ''}'),
                      Text('Branch: ${userData?['branch'] ?? ''}'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _attendanceHistory.isEmpty
                ? const Center(child: Text('No attendance records found'))
                : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Recent Attendance',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: _loadAttendanceHistory,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _attendanceHistory.length,
                    itemBuilder: (context, index) {
                      final record = _attendanceHistory[index];
                      final course = record['courses'];
                      final status = record['status'];

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: status == 'present'
                                ? Colors.green
                                : status == 'late'
                                ? Colors.orange
                                : Colors.red,
                            child: Icon(
                              status == 'present'
                                  ? Icons.check
                                  : status == 'late'
                                  ? Icons.access_time
                                  : Icons.close,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(course['course_name']),
                          subtitle: Text('${course['course_id']} - ${record['date']}'),
                          trailing: Text(
                            status,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: status == 'present'
                                  ? Colors.green
                                  : status == 'late'
                                  ? Colors.orange
                                  : Colors.red,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
// Face detector stub class (in a real app, this would be implemented with a real face recognition library)
class FaceDetector {
  static Future<List<Face>> detectFaces(String imagePath) async {
    // In a real app, this would call a face recognition API
    // For demo purposes, we return a dummy face
    return [Face(1), Face(2)]; // Simulating two detected faces
  }
}

class Face {
  final int id;

  Face(this.id);

  @override
  String toString() => 'face_$id';
}

// Add these at the top of your student_dashboard.dart file

class AttendanceStatsPage extends StatefulWidget {
  final int studentId;

  const AttendanceStatsPage({Key? key, required this.studentId}) : super(key: key);

  @override
  _AttendanceStatsPageState createState() => _AttendanceStatsPageState();
}

class _AttendanceStatsPageState extends State<AttendanceStatsPage> {
  Map<String, Map<String, int>> _courseAttendance = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadAttendanceStats();
  }

  Future<void> _loadAttendanceStats() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final supabase = Supabase.instance.client;

      // Use the unified attendance_records table
      final attendanceData = await supabase
          .from('attendance_records')
          .select('course_id, status, courses(course_name)')
          .eq('student_id', widget.studentId);

      final Map<String, Map<String, int>> stats = {};

      for (final record in attendanceData) {
        final courseId = record['course_id'];
        final status = record['status'];
        final courseName = record['courses']['course_name'];

        if (!stats.containsKey(courseId)) {
          stats[courseId] = {
            'present': 0,
            'absent': 0,
            'late': 0,
            'total': 0,
          };
          // Store course name as a special field
          stats[courseId]!['_course_name'] = courseName;
        }

        stats[courseId]![status] = (stats[courseId]![status] ?? 0) + 1;
        stats[courseId]!['total'] = (stats[courseId]!['total'] ?? 0) + 1;
      }

      setState(() {
        _courseAttendance = stats;
      });
    } catch (e) {
      debugPrint('Error loading attendance stats: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Statistics'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _courseAttendance.isEmpty
          ? const Center(child: Text('No attendance data available'))
          : ListView(
        padding: const EdgeInsets.all(16.0),
        children: _courseAttendance.entries.map((entry) {
          final courseId = entry.key;
          final stats = entry.value;
          final courseName = (stats['_course_name'] as String?) ?? courseId;

          final total = stats['total'] ?? 0;
          final presentPercentage = total > 0
              ? (stats['present'] ?? 0) / total * 100
              : 0.0;

          return Card(
            margin: const EdgeInsets.only(bottom: 16.0),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    courseName,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Course ID: $courseId',
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 200,
                    child: PieChart(
                      PieChartData(
                        sections: [
                          PieChartSectionData(
                            value: stats['present']?.toDouble() ?? 0,
                            title: 'Present',
                            color: Colors.green,
                            radius: 60,
                          ),
                          PieChartSectionData(
                            value: stats['late']?.toDouble() ?? 0,
                            title: 'Late',
                            color: Colors.orange,
                            radius: 60,
                          ),
                          PieChartSectionData(
                            value: stats['absent']?.toDouble() ?? 0,
                            title: 'Absent',
                            color: Colors.red,
                            radius: 60,
                          ),
                        ],
                        sectionsSpace: 2,
                        centerSpaceRadius: 40,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Present: ${stats['present'] ?? 0} times',
                    style: const TextStyle(color: Colors.green),
                  ),
                  Text(
                    'Late: ${stats['late'] ?? 0} times',
                    style: const TextStyle(color: Colors.orange),
                  ),
                  Text(
                    'Absent: ${stats['absent'] ?? 0} times',
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Attendance Rate: ${presentPercentage.toStringAsFixed(1)}%',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
