import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'audio_stub.dart' if (dart.library.js) 'audio_web.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

// ==========================================
// CONFIGURATION: SETUP YOUR SUPABASE DETAILS
// ==========================================
const String supabaseUrl = 'https://okhcuocbflkmelugvvmh.supabase.co';
const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9raGN1b2NiZmxrbWVsdWd2dm1oIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5MjgyMzIsImV4cCI6MjA5NjUwNDIzMn0.hdLKtrhkZOmm7SebMlMlBGjTY8_Sg5zdjXOCPdpav1o';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool isSupabaseConfigured = false;
  
  if (supabaseUrl != 'YOUR_SUPABASE_URL' && 
      supabaseAnonKey != 'YOUR_SUPABASE_ANON_KEY' &&
      supabaseUrl.isNotEmpty && 
      supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
      );
      isSupabaseConfigured = true;
    } catch (e) {
      debugPrint('Supabase Initialization Failed: $e');
    }
  }

  runApp(CashierApp(isSupabaseConfigured: isSupabaseConfigured));
}

class CashierApp extends StatelessWidget {
  final bool isSupabaseConfigured;

  const CashierApp({super.key, required this.isSupabaseConfigured});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'E-Wisata POS Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        fontFamily: 'Segoe UI, Roboto, Helvetica Neue, sans-serif',
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF10B981),
          surface: Colors.white,
        ),
      ),
      home: CashierHomePage(isSupabaseConfigured: isSupabaseConfigured),
    );
  }
}

enum TransactionStatus {
  waitingForInput,
  waitingForCard,
  processing,
  success,
  failed,
}

class CashierHomePage extends StatefulWidget {
  final bool isSupabaseConfigured;

  const CashierHomePage({super.key, required this.isSupabaseConfigured});

  @override
  State<CashierHomePage> createState() => _CashierHomePageState();
}

class _CashierHomePageState extends State<CashierHomePage> with TickerProviderStateMixin {
  // Access and Navigation State
  bool _isAdminMode = false;
  bool _isInitialized = false;
  int _currentTab = 0; // Index mapping adapts depending on _isAdminMode
  bool _showSimulator = false; // Initialized in didChangeDependencies based on screen size
  bool _isPrinting = false; // Simulation of Bluetooth printer loading state
  bool _isExporting = false; // Simulation of Excel/PDF export loading state
  String _activeTimeFilter = 'Hari Ini'; // Stats tab filter option

  // Global State Machine variables
  TransactionStatus _currentStatus = TransactionStatus.waitingForInput;
  String _statusMessage = 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
  
  // Amounts
  int _cashierAmount = 0;
  int _topUpAmount = 0;
  
  // NFC Card / RFID states
  String? nfcUid;
  int? remainingSaldo; // Cashier mode success variable
  int? loadedNewSaldo; // Top up mode success variable
  String? touristName; // Loaded name on card detection

  // Dynamic Merchant / Warung variables
  List<Map<String, dynamic>> _merchantsList = [];
  int? _selectedMerchantId;

  // Merchant Dashboard Data variables (Merchant role)
  bool _isLoadingDashboard = false;
  int _totalEarnings = 0;
  int _totalTransactionsCount = 0;
  List<Map<String, dynamic>> _recentTransactions = [];

  // Admin Overview Data variables (Admin role)
  bool _isLoadingAdminDashboard = false;
  int _totalTopUpsSum = 0;
  int _totalSpendingsSum = 0;
  List<Map<String, dynamic>> _bestSellingMerchants = [];
  List<Map<String, dynamic>> _allTransactionsGlobal = [];

  // Animation controller for pulsing card reader concentric rings
  late AnimationController _pulseController;

  // Tab mappings helper getters
  bool get _isOverviewTab => _isAdminMode && _currentTab == 0;
  bool get _isCashierTab => (_isAdminMode && _currentTab == 1) || (!_isAdminMode && _currentTab == 0);
  bool get _isTopUpTab => (_isAdminMode && _currentTab == 2) || (!_isAdminMode && _currentTab == 1);
  bool get _isHistoryTab => (_isAdminMode && _currentTab == 3) || (!_isAdminMode && _currentTab == 2);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    
    // Fetch merchants then dashboards
    _fetchMerchants().then((_) {
      _fetchDashboardData();
      _fetchAdminDashboardData();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      final double screenWidth = MediaQuery.of(context).size.width;
      _isAdminMode = screenWidth >= 900;
      _showSimulator = kIsWeb && screenWidth >= 900; // Simulator only on desktop web
      if (_isAdminMode) {
        _currentTab = 0;
        _fetchAdminDashboardData();
      } else {
        _currentTab = 0;
      }
      _isInitialized = true;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    if (!kIsWeb) {
      NfcManager.instance.stopSession().catchError((_) {});
    }
    super.dispose();
  }

  // Play a POS scanner beep sound
  void _playBeepSound() {
    if (kIsWeb) {
      playWebBeepSound();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  // Formatting utility for Rupiah
  String _formatCurrency(int value) {
    String strVal = value.toString();
    String formatted = '';
    int count = 0;
    for (int i = strVal.length - 1; i >= 0; i--) {
      formatted = strVal[i] + formatted;
      count++;
      if (count == 3 && i > 0) {
        formatted = '.' + formatted;
        count = 0;
      }
    }
    return 'Rp ' + formatted;
  }

  String _formatTime(String isoString) {
    try {
      final dateTime = DateTime.parse(isoString).toLocal();
      final hour = dateTime.hour.toString().padLeft(2, '0');
      final minute = dateTime.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '12:00';
    }
  }

  // Fetches list of registered merchants from Supabase
  Future<void> _fetchMerchants() async {
    if (!widget.isSupabaseConfigured) {
      setState(() {
        _merchantsList = [
          {'id': 1, 'nama_warung': 'Warung Kelapa Muda Pak Agus', 'nama_pemilik': 'Pak Agus'},
          {'id': 2, 'nama_warung': 'Toko Souvenir Candi Prambanan', 'nama_pemilik': 'Bu Sri'},
          {'id': 3, 'nama_warung': 'Kedai Kopi Kuliner Kuta', 'nama_pemilik': 'Bli Made'},
        ];
        _selectedMerchantId = 1;
      });
      return;
    }
    
    try {
      final supabase = Supabase.instance.client;
      final List<dynamic> response = await supabase
          .from('merchants')
          .select('id, nama_warung, nama_pemilik')
          .order('nama_warung', ascending: true);
          
      setState(() {
        _merchantsList = List<Map<String, dynamic>>.from(response);
        if (_merchantsList.isNotEmpty) {
          if (_selectedMerchantId == null || !_merchantsList.any((m) => m['id'] == _selectedMerchantId)) {
            _selectedMerchantId = _merchantsList[0]['id'];
          }
        }
      });
    } catch (e) {
      debugPrint('Error fetching merchants: $e');
      setState(() {
        _merchantsList = [
          {'id': 1, 'nama_warung': 'Warung Utama (Fallback)', 'nama_pemilik': 'Default'},
        ];
        _selectedMerchantId = 1;
      });
    }
  }

  // Fetches real-time transaction reports directly from Supabase for a single merchant
  Future<void> _fetchDashboardData() async {
    if (_isLoadingDashboard) return;
    
    setState(() {
      _isLoadingDashboard = true;
    });

    final int activeMerchant = _selectedMerchantId ?? 1;

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(milliseconds: 300));
      setState(() {
        _totalEarnings = 710000;
        _totalTransactionsCount = 5;
        _recentTransactions = [
          {'id': 1, 'nominal': 5000, 'created_at': DateTime.now().toIso8601String(), 'users': {'nama': 'Budi Wisatawan'}},
          {'id': 2, 'nominal': 25000, 'created_at': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(), 'users': {'nama': 'Siti Travela'}},
          {'id': 3, 'nominal': 80000, 'created_at': DateTime.now().subtract(const Duration(minutes: 15)).toIso8601String(), 'users': {'nama': 'Andi Explorer'}},
          {'id': 4, 'nominal': 50000, 'created_at': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(), 'users': {'nama': 'Dewi Journey'}},
          {'id': 5, 'nominal': 200000, 'created_at': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(), 'users': {'nama': 'Top-Up Saldo'}},
        ];
        _isLoadingDashboard = false;
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch transactions list joined with user names for this merchant
      final List<dynamic> response = await supabase
          .from('transactions')
          .select('id, nominal, created_at, users(nama)')
          .eq('merchant_id', activeMerchant)
          .order('created_at', ascending: false)
          .limit(10);

      final List<Map<String, dynamic>> parsedList = List<Map<String, dynamic>>.from(response);

      // 2. Fetch sum of nominals for this merchant
      final List<dynamic> sumResponse = await supabase
          .from('transactions')
          .select('nominal')
          .eq('merchant_id', activeMerchant);
      
      int sumEarnings = 0;
      for (var row in sumResponse) {
        sumEarnings += (row['nominal'] as num).toInt();
      }

      setState(() {
        _recentTransactions = parsedList;
        _totalEarnings = sumEarnings;
        _totalTransactionsCount = sumResponse.length;
        _isLoadingDashboard = false;
      });
    } catch (e) {
      debugPrint('Error fetching dashboard stats: $e');
      setState(() {
        _isLoadingDashboard = false;
      });
    }
  }

  // Fetches global transaction statistics for the Central Admin Dashboard
  Future<void> _fetchAdminDashboardData() async {
    if (_isLoadingAdminDashboard) return;
    setState(() {
      _isLoadingAdminDashboard = true;
    });

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(milliseconds: 300));
      setState(() {
        _totalSpendingsSum = 710000;
        _totalTopUpsSum = 970800; // Total money in system = current balances (~260k) + spendings (~710k)
        
        _allTransactionsGlobal = [
          {'id': 1, 'nominal': 5000, 'created_at': DateTime.now().toIso8601String(), 'users': {'nama': 'Budi Wisatawan'}, 'merchants': {'nama_warung': 'Warung Kelapa Muda Pak Agus'}},
          {'id': 2, 'nominal': 25000, 'created_at': DateTime.now().subtract(const Duration(minutes: 15)).toIso8601String(), 'users': {'nama': 'Siti Travela'}, 'merchants': {'nama_warung': 'Toko Souvenir Candi Prambanan'}},
          {'id': 3, 'nominal': 80000, 'created_at': DateTime.now().subtract(const Duration(minutes: 30)).toIso8601String(), 'users': {'nama': 'Andi Explorer'}, 'merchants': {'nama_warung': 'Kedai Kopi Kuliner Kuta'}},
          {'id': 4, 'nominal': 50000, 'created_at': DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(), 'users': {'nama': 'Dewi Journey'}, 'merchants': {'nama_warung': 'Warung Kelapa Muda Pak Agus'}},
        ];
        
        _bestSellingMerchants = [
          {'nama_warung': 'Warung Kelapa Muda Pak Agus', 'total_omzet': 710000},
          {'nama_warung': 'Kedai Kopi Kuliner Kuta', 'total_omzet': 120000},
          {'nama_warung': 'Toko Souvenir Candi Prambanan', 'total_omzet': 80000},
        ];
        _isLoadingAdminDashboard = false;
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch sum of balances of all users
      final usersResponse = await supabase.from('users').select('saldo');
      int sumBalances = 0;
      for (var u in usersResponse) {
        sumBalances += (u['saldo'] as num?)?.toInt() ?? 0;
      }

      // 2. Fetch all transactions for calculations
      final txResponse = await supabase
          .from('transactions')
          .select('id, nominal, created_at, users(nama), merchants(nama_warung)')
          .order('created_at', ascending: false);

      final List<Map<String, dynamic>> allTx = List<Map<String, dynamic>>.from(txResponse);

      int sumSpendings = 0;
      Map<String, int> merchantSales = {};
      
      for (var m in _merchantsList) {
        String name = m['nama_warung'] ?? 'Warung';
        merchantSales[name] = 0;
      }

      for (var tx in allTx) {
        final nominal = (tx['nominal'] as num?)?.toInt() ?? 0;
        sumSpendings += nominal;
        
        final merchantName = tx['merchants']?['nama_warung'] ?? 'Warung Umum';
        merchantSales[merchantName] = (merchantSales[merchantName] ?? 0) + nominal;
      }

      final rankedMerchantsList = merchantSales.entries
          .map((e) => {'nama_warung': e.key, 'total_omzet': e.value})
          .toList()
        ..sort((a, b) => (b['total_omzet'] as int).compareTo(a['total_omzet'] as int));

      setState(() {
        _totalSpendingsSum = sumSpendings;
        _totalTopUpsSum = sumBalances + sumSpendings;
        _allTransactionsGlobal = allTx;
        _bestSellingMerchants = rankedMerchantsList;
        _isLoadingAdminDashboard = false;
      });
    } catch (e) {
      debugPrint('Error fetching admin dashboard: $e');
      setState(() {
        _isLoadingAdminDashboard = false;
      });
    }
  }

  // Keypad Tap handlers based on the active tab
  void _handleKeypadTap(String value) {
    if (_currentStatus != TransactionStatus.waitingForInput &&
        _currentStatus != TransactionStatus.success &&
        _currentStatus != TransactionStatus.failed) {
      return; 
    }

    if (_currentStatus == TransactionStatus.success || _currentStatus == TransactionStatus.failed) {
      _resetTransaction();
    }

    setState(() {
      int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;

      if (value == 'C') {
        activeAmount = 0;
      } else if (value == '⌫') {
        String currentStr = activeAmount.toString();
        if (currentStr.length > 1) {
          activeAmount = int.parse(currentStr.substring(0, currentStr.length - 1));
        } else {
          activeAmount = 0;
        }
      } else {
        String currentStr = activeAmount == 0 ? '' : activeAmount.toString();
        if (currentStr.length < 9) {
          activeAmount = int.parse(currentStr + value);
        }
      }

      if (_isCashierTab) {
        _cashierAmount = activeAmount;
        _statusMessage = _cashierAmount > 0 
            ? 'Siap diproses: ${_formatCurrency(_cashierAmount)}' 
            : 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
      } else {
        _topUpAmount = activeAmount;
        _statusMessage = _topUpAmount > 0 
            ? 'Siap top-up: ${_formatCurrency(_topUpAmount)}' 
            : 'Masukkan nominal top-up dan ketuk Proses Top-Up.';
      }
    });
  }

  void _addQuickAmount(int amount) {
    if (_currentStatus == TransactionStatus.processing || 
        _currentStatus == TransactionStatus.waitingForCard) {
      return;
    }
    
    if (_currentStatus == TransactionStatus.success || _currentStatus == TransactionStatus.failed) {
      _resetTransaction();
    }

    setState(() {
      if (_isCashierTab) {
        _cashierAmount += amount;
        _statusMessage = 'Siap diproses: ${_formatCurrency(_cashierAmount)}';
      } else {
        _topUpAmount += amount;
        _statusMessage = 'Siap top-up: ${_formatCurrency(_topUpAmount)}';
      }
    });
  }

  void _clearAmount() {
    setState(() {
      if (_isCashierTab) {
        _cashierAmount = 0;
        _statusMessage = 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
      } else {
        _topUpAmount = 0;
        _statusMessage = 'Masukkan nominal top-up dan ketuk Proses Top-Up.';
      }
    });
  }

  void _resetTransaction() {
    if (!kIsWeb) {
      NfcManager.instance.stopSession().catchError((_) {});
    }
    setState(() {
      _cashierAmount = 0;
      _topUpAmount = 0;
      nfcUid = null;
      remainingSaldo = null;
      loadedNewSaldo = null;
      touristName = null;
      _currentStatus = TransactionStatus.waitingForInput;
      if (_isCashierTab) {
        _statusMessage = 'Masukkan nominal belanja dan pilih Proses Pembayaran.';
      } else {
        _statusMessage = 'Masukkan nominal top-up dan ketuk Proses Top-Up.';
      }
    });
    _fetchDashboardData();
    if (_isAdminMode) _fetchAdminDashboardData();
  }

  // Deduct balance logic (Tab 0)
  Future<void> prosesPotongSaldo(String uid, int nominal) async {
    setState(() {
      _currentStatus = TransactionStatus.processing;
      _statusMessage = 'Memproses pemotongan saldo...';
    });

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(seconds: 1));
      if (uid == '00:00:00:00') {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Souvenir Tidak Terdaftar!';
        });
        return;
      }
      
      int mockUserSaldo = 150000;
      if (mockUserSaldo < nominal) {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Saldo Wisatawan Tidak Cukup!';
        });
        return;
      }
      
      _playBeepSound();
      setState(() {
        touristName = 'Budi Wisatawan';
        remainingSaldo = mockUserSaldo - nominal;
        _currentStatus = TransactionStatus.success;
        _statusMessage = 'Pembayaran Berhasil!';
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch user by nfc_uid
      final userData = await supabase
          .from('users')
          .select('id, saldo, nama')
          .eq('nfc_uid', uid)
          .maybeSingle();

      if (userData == null) {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Souvenir Tidak Terdaftar!';
        });
        return;
      }

      final userId = userData['id'];
      final int currentSaldo = userData['saldo'] ?? 0;
      final String name = userData['nama'];

      // 2. Check balance
      if (currentSaldo < nominal) {
        setState(() {
          _currentStatus = TransactionStatus.failed;
          _statusMessage = 'Error: Saldo Wisatawan Tidak Cukup!';
        });
        return;
      }

      // 3. Update balance
      final int newSaldo = currentSaldo - nominal;
      await supabase
          .from('users')
          .update({'saldo': newSaldo})
          .eq('id', userId);

      // 4. Record transaction log
      await supabase.from('transactions').insert({
        'user_id': userId,
        'merchant_id': _selectedMerchantId ?? 1,
        'nominal': nominal,
        'created_at': DateTime.now().toIso8601String(),
      });

      _playBeepSound();
      setState(() {
        touristName = name;
        remainingSaldo = newSaldo;
        _currentStatus = TransactionStatus.success;
        _statusMessage = 'Pembayaran Berhasil!';
      });

      if (!kIsWeb) {
        await NfcManager.instance.stopSession().catchError((_) {});
      }
    } catch (e) {
      debugPrint('Deduct balance transaction error: $e');
      setState(() {
        _currentStatus = TransactionStatus.failed;
        _statusMessage = 'Error: Gagal memproses transaksi ($e)';
      });
    }
  }

  // Top-Up balance logic (Tab 1)
  Future<void> prosesTopUpSaldo(String uid, int nominal) async {
    setState(() {
      _currentStatus = TransactionStatus.processing;
      _statusMessage = 'Memproses penambahan saldo...';
    });

    if (!widget.isSupabaseConfigured) {
      await Future.delayed(const Duration(seconds: 1));
      _playBeepSound();
      setState(() {
        touristName = 'Budi Wisatawan';
        loadedNewSaldo = 150000 + nominal;
        _currentStatus = TransactionStatus.success;
        _statusMessage = 'Top-Up Berhasil!';
      });
      return;
    }

    try {
      final supabase = Supabase.instance.client;

      // 1. Check if user already exists
      final userData = await supabase
          .from('users')
          .select('id, saldo, nama')
          .eq('nfc_uid', uid)
          .maybeSingle();

      if (userData != null) {
        final userId = userData['id'];
        final int currentSaldo = userData['saldo'] ?? 0;
        final String name = userData['nama'];
        final int newSaldo = currentSaldo + nominal;

        await supabase
            .from('users')
            .update({'saldo': newSaldo})
            .eq('id', userId);

        _playBeepSound();
        setState(() {
          touristName = name;
          loadedNewSaldo = newSaldo;
          _currentStatus = TransactionStatus.success;
          _statusMessage = 'Top-Up Berhasil!';
        });
      } else {
        // Option B: New card scanned! Auto-register as a new tourist
        String newTouristName = 'Wisatawan #${uid.substring(uid.length - 5).replaceAll(':', '')}';
        
        await supabase.from('users').insert({
          'nama': newTouristName,
          'nfc_uid': uid,
          'saldo': nominal,
          'created_at': DateTime.now().toIso8601String(),
        });

        _playBeepSound();
        setState(() {
          touristName = newTouristName;
          loadedNewSaldo = nominal;
          _currentStatus = TransactionStatus.success;
          _statusMessage = 'Pendaftaran & Top-Up Berhasil!';
        });
      }

      if (!kIsWeb) {
        await NfcManager.instance.stopSession().catchError((_) {});
      }
    } catch (e) {
      debugPrint('Top Up Supabase transaction error: $e');
      setState(() {
        _currentStatus = TransactionStatus.failed;
        _statusMessage = 'Error: Gagal melakukan pengisian ($e)';
      });
    }
  }

  // NFC Session Initiations
  Future<void> _startPaymentProcess() async {
    int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;
    if (activeAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isCashierTab ? 'Nominal belanja tidak boleh kosong!' : 'Nominal top-up tidak boleh kosong!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() {
      _currentStatus = TransactionStatus.waitingForCard;
      _statusMessage = _isCashierTab
          ? 'Silahkan tempel souvenir RFID ke belakang HP...'
          : 'Tempelkan souvenir RFID untuk menambahkan saldo...';
      nfcUid = null;
      remainingSaldo = null;
      loadedNewSaldo = null;
      touristName = null;
    });

    if (kIsWeb) return; 

    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sensor NFC tidak didukung pada perangkat ini. Gunakan simulator di layar untuk menguji.'),
          backgroundColor: Colors.amber,
          duration: Duration(seconds: 4),
        ),
      );
    }

    try {
      await NfcManager.instance.startSession(
        onDiscovered: (NfcTag tag) async {
          final idBytes = _getNfcId(tag);
          if (idBytes != null) {
            final String formattedUid = _toHexString(idBytes);
            setState(() {
              nfcUid = formattedUid;
            });
            HapticFeedback.vibrate();
            await NfcManager.instance.stopSession();
            
            if (_isCashierTab) {
              await prosesPotongSaldo(formattedUid, _cashierAmount);
            } else {
              await prosesTopUpSaldo(formattedUid, _topUpAmount);
            }
          } else {
            setState(() {
              _statusMessage = 'RFID terdeteksi, tetapi UID tidak terbaca.';
            });
            await NfcManager.instance.stopSession(errorMessage: 'Gagal membaca UID.');
          }
        },
        onError: (error) async {
          setState(() {
            _currentStatus = TransactionStatus.failed;
            _statusMessage = 'NFC Error: ${error.message}';
          });
        }
      );
    } catch (e) {
      debugPrint('Error starting NFC Session: $e');
    }
  }

  Future<void> _simulateCardTap() async {
    if (_currentStatus != TransactionStatus.waitingForCard) return;

    setState(() {
      _currentStatus = TransactionStatus.processing;
      _statusMessage = 'Membaca data chip RFID...';
    });

    await Future.delayed(const Duration(seconds: 1));
    const String mockUid = '04:A2:B3:C4';

    setState(() {
      nfcUid = mockUid;
    });

    HapticFeedback.vibrate();
    
    if (_isCashierTab) {
      await prosesPotongSaldo(mockUid, _cashierAmount);
    } else {
      await prosesTopUpSaldo(mockUid, _topUpAmount);
    }
  }

  // Security Access Management (PIN)
  void _showPINDialog() {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: Color(0xFF3B82F6)),
              SizedBox(width: 10),
              Text('Mode Pengelola', style: TextStyle(color: Color(0xFF0F172A), fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Masukkan PIN Keamanan Pusat:', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
              const SizedBox(height: 14),
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2),
                  ),
                  counterText: '',
                  hintText: 'Masukkan PIN',
                ),
                style: const TextStyle(color: Color(0xFF0F172A), fontSize: 20, letterSpacing: 8, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Batal', style: TextStyle(color: Color(0xFF64748B))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () {
                if (pinController.text == '2026') {
                  Navigator.pop(context);
                  setState(() {
                    _isAdminMode = true;
                    _currentTab = 0; // Default to Admin Overview
                    _resetTransaction();
                  });
                  _fetchAdminDashboardData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Selamat Datang, Pengelola Pusat!'), backgroundColor: Colors.green),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PIN Salah! Akses Ditolak.'), backgroundColor: Colors.redAccent),
                  );
                }
              },
              child: const Text('Masuk'),
            ),
          ],
        );
      },
    );
  }

  void _exitAdminMode() {
    setState(() {
      _isAdminMode = false;
      _currentTab = 0; // Default to Cashier Belanja
      _resetTransaction();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Keluar dari Mode Pengelola.'), backgroundColor: Colors.blueGrey),
    );
  }

  // Generate real PDF receipt and open print/save dialog
  Future<void> _generatePdfReceipt() async {
    if (_isPrinting) return;
    setState(() { _isPrinting = true; });

    final String merchantName = _merchantsList.firstWhere(
      (m) => m['id'] == _selectedMerchantId,
      orElse: () => {'nama_warung': 'Kasir'},
    )['nama_warung'] ?? 'Kasir';
    final String dateStr = DateTime.now().toString().substring(0, 16);
    final bool isCashier = _isCashierTab;

    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (pw.Context context) {
          return pw.Center(
            child: pw.Container(
              width: 260,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('E-WISATA CASHLESS', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    isCashier ? 'Nota Belanja Souvenir Resmi' : 'Kuitansi Pengisian Saldo Resmi',
                    style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
                  ),
                  pw.SizedBox(height: 12),
                  pw.Divider(thickness: 0.8, color: PdfColors.grey400),
                  pw.SizedBox(height: 10),
                  _pdfRow('Wisatawan', touristName ?? 'N/A'),
                  _pdfRow('UID Kartu', nfcUid ?? 'N/A'),
                  _pdfRow('Loket Kasir', merchantName),
                  _pdfRow('Waktu', dateStr),
                  pw.SizedBox(height: 8),
                  pw.Divider(thickness: 0.5, color: PdfColors.grey300),
                  pw.SizedBox(height: 8),
                  if (isCashier) ...[
                    _pdfRow('Nominal Belanja', _formatCurrency(_cashierAmount), bold: true),
                    _pdfRow('Sisa Saldo', remainingSaldo != null ? _formatCurrency(remainingSaldo!) : 'N/A', bold: true),
                  ] else ...[
                    _pdfRow('Jumlah Top-Up', _formatCurrency(_topUpAmount), bold: true),
                    _pdfRow('Saldo Akhir', loadedNewSaldo != null ? _formatCurrency(loadedNewSaldo!) : 'N/A', bold: true),
                  ],
                  pw.SizedBox(height: 8),
                  pw.Divider(thickness: 0.8, color: PdfColors.grey400),
                  pw.SizedBox(height: 16),
                  pw.BarcodeWidget(
                    data: 'EWISATA-${nfcUid ?? "0000"}-$dateStr',
                    barcode: pw.Barcode.qrCode(),
                    width: 80,
                    height: 80,
                  ),
                  pw.SizedBox(height: 6),
                  pw.Text(
                    isCashier ? 'TIKET WAHANA VALID' : 'SINKRONISASI CLOUD BERHASIL',
                    style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800),
                  ),
                  pw.SizedBox(height: 16),
                  pw.Text('Terima kasih telah berkunjung!', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey500)),
                  pw.Text('E-Wisata Cashless System', style: pw.TextStyle(fontSize: 7, color: PdfColors.grey400)),
                ],
              ),
            ),
          );
        },
      ),
    );

    setState(() { _isPrinting = false; });

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Struk_EWisata_${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  // Generate real PDF transaction report
  Future<void> _generatePdfReport() async {
    if (_isExporting) return;
    setState(() { _isExporting = true; });

    final pdf = pw.Document();
    final String dateStr = DateTime.now().toString().substring(0, 16);
    final double avgVal = _allTransactionsGlobal.isNotEmpty
        ? _totalSpendingsSum / _allTransactionsGlobal.length
        : 0.0;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('E-WISATA CASHLESS', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                  pw.Text('Laporan Transaksi', style: pw.TextStyle(fontSize: 12, color: PdfColors.grey600)),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Text('Dicetak: $dateStr', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey500)),
              pw.Divider(thickness: 1),
              pw.SizedBox(height: 8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  _pdfStatBox('Total Transaksi', '${_allTransactionsGlobal.length}'),
                  _pdfStatBox('Total Nilai', _formatCurrency(_totalSpendingsSum)),
                  _pdfStatBox('Rata-rata', _formatCurrency(avgVal.toInt())),
                ],
              ),
              pw.SizedBox(height: 12),
            ],
          );
        },
        build: (pw.Context context) => [
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blue800),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellHeight: 28,
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerLeft,
              3: pw.Alignment.centerRight,
              4: pw.Alignment.center,
            },
            headers: ['No', 'Wisatawan', 'Merchant', 'Nominal', 'Waktu'],
            data: _allTransactionsGlobal.asMap().entries.map((entry) {
              final tx = entry.value;
              return [
                '${entry.key + 1}',
                tx['users'] != null ? tx['users']['nama'] ?? 'Wisatawan' : 'Wisatawan',
                tx['merchants'] != null ? tx['merchants']['nama_warung'] ?? 'Warung' : 'Warung',
                _formatCurrency((tx['nominal'] as num?)?.toInt() ?? 0),
                _formatTime(tx['created_at'] ?? ''),
              ];
            }).toList(),
          ),
        ],
      ),
    );

    setState(() { _isExporting = false; });

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Laporan_EWisata_${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  // PDF helper: row with label-value pair
  pw.Widget _pdfRow(String label, String value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.Text(value, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ],
      ),
    );
  }

  // PDF helper: stat box for report header
  pw.Widget _pdfStatBox(String label, String value) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
          pw.SizedBox(height: 4),
          pw.Text(value, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );
  }

  // UI Build methods
  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = screenWidth >= 900;

    return Scaffold(
      body: Row(
        children: [
          // Premium Left Navigation Sidebar (Desktop only)
          if (isDesktop) _buildDesktopNavSidebar(),

          // Center POS Input Column (Or Full Admin Dashboard)
          Expanded(
            flex: isDesktop ? ( (_isOverviewTab || _isHistoryTab) ? 12 : 6 ) : 1,
            child: Container(
              color: const Color(0xFFF8FAFC), // Apple Soft Grey Canvas
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPOSHeader(),
                      const SizedBox(height: 16),
                      
                      // Active dropdown for merchants in cashier mode
                      _buildMerchantSelector(),
                      
                      _isHistoryTab || _isOverviewTab 
                          ? const SizedBox.shrink() 
                          : _buildLEDAmountDisplay(),
                      const SizedBox(height: 14),
                      
                      _isHistoryTab || _isOverviewTab 
                          ? const SizedBox.shrink() 
                          : _buildQuickAmountSelector(),
                      const SizedBox(height: 16),
                      
                      Expanded(
                        child: _isOverviewTab
                            ? _buildAdminOverviewView()
                            : (_isHistoryTab 
                                ? (_isAdminMode ? _buildGlobalHistoryView() : _buildDashboardView()) 
                                : _buildDigitalKeypad()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          
          // Right POS Terminal Column (Payment Status & NFC wireless animations - Desktop only)
          if (isDesktop && !_isOverviewTab && !_isHistoryTab)
            Expanded(
              flex: 5,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F5F9), // Light grey terminal console background
                  border: Border(
                    left: BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: _buildTerminalConsole(),
                  ),
                ),
              ),
            ),
        ],
      ),
      // Mobile Bottom Sheets & Navigation Bar
      bottomNavigationBar: !isDesktop ? _buildMobileNavBar() : null,
      bottomSheet: !isDesktop && _currentStatus != TransactionStatus.waitingForInput && !_isOverviewTab && !_isHistoryTab
          ? _buildMobileTerminalOverlay()
          : null,
    );
  }

  // Sidebar navigation panel for desktop POS Terminal (Apple Style White Panel)
  Widget _buildDesktopNavSidebar() {
    return Container(
      width: 260,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand Logo
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF3B82F6), size: 24),
              ),
              const SizedBox(width: 12),
              const Text(
                'E-WISATA PAY',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: 1.0),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isAdminMode ? const Color(0xFFFFF1F2) : const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _isAdminMode ? '🛡️ MODE PUSAT (ADMIN)' : '🏪 MODE KASIR WARUNG',
              style: TextStyle(
                fontSize: 10, 
                color: _isAdminMode ? const Color(0xFFF43F5E) : const Color(0xFF10B981), 
                fontWeight: FontWeight.bold, 
                letterSpacing: 0.5
              ),
            ),
          ),
          const SizedBox(height: 36),
          
          // Menu Items (Apple/Gojek grid menu style inside sidebar)
          if (_isAdminMode) ...[
            _buildSidebarNavItem(0, Icons.analytics_rounded, 'Overview Pusat', const Color(0xFFEFF6FF), const Color(0xFF3B82F6)),
            const SizedBox(height: 12),
            _buildSidebarNavItem(1, Icons.point_of_sale_rounded, 'Kasir Belanja', const Color(0xFFF5F3FF), const Color(0xFF8B5CF6)),
            const SizedBox(height: 12),
            _buildSidebarNavItem(2, Icons.add_card_rounded, 'Top-Up Saldo', const Color(0xFFECFDF5), const Color(0xFF10B981)),
            const SizedBox(height: 12),
            _buildSidebarNavItem(3, Icons.list_alt_rounded, 'Riwayat Global', const Color(0xFFFFF1F2), const Color(0xFFF43F5E)),
          ] else ...[
            _buildSidebarNavItem(0, Icons.point_of_sale_rounded, 'Kasir Belanja', const Color(0xFFF5F3FF), const Color(0xFF8B5CF6)),
            const SizedBox(height: 12),
            _buildSidebarNavItem(1, Icons.add_card_rounded, 'Top-Up Saldo', const Color(0xFFECFDF5), const Color(0xFF10B981)),
            const SizedBox(height: 12),
            _buildSidebarNavItem(2, Icons.history_rounded, 'Riwayat Warung', const Color(0xFFFFF1F2), const Color(0xFFF43F5E)),
          ],
          
          const Spacer(),

          // Admin Access Toggle
          InkWell(
            onTap: _isAdminMode ? _exitAdminMode : _showPINDialog,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: _isAdminMode ? const Color(0xFFFFF1F2) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isAdminMode ? const Color(0xFFFECDD3) : const Color(0xFFE2E8F0),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isAdminMode ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                    color: _isAdminMode ? const Color(0xFFF43F5E) : const Color(0xFF64748B),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isAdminMode ? 'Keluar Admin' : 'Masuk Admin',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: _isAdminMode ? const Color(0xFFF43F5E) : const Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Supabase Status
          _buildOnlineStatusBadge(),
        ],
      ),
    );
  }

  Widget _buildOnlineStatusBadge() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.isSupabaseConfigured ? const Color(0xFF10B981) : Colors.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.isSupabaseConfigured ? 'Database Online' : 'Sandbox Offline',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.isSupabaseConfigured 
                ? 'Sinkronisasi cloud aktif.' 
                : 'Data hanya disimpan lokal.',
            style: const TextStyle(fontSize: 9, color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }

  // Apple style Nav Sidebar item with rounded shapes and pastel circle background for icon
  Widget _buildSidebarNavItem(int index, IconData icon, String label, Color pastelBg, Color accentColor) {
    final bool isSelected = _currentTab == index;
    return InkWell(
      onTap: () {
        setState(() {
          _currentTab = index;
          _resetTransaction();
        });
        if (_isAdminMode && index == 0) {
          _fetchAdminDashboardData();
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF1F5F9) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFFE2E8F0) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: pastelBg,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accentColor, size: 20),
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? const Color(0xFF0F172A) : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPOSHeader() {
    String titleText = '';
    if (_isOverviewTab) {
      titleText = 'Monitoring Pusat';
    } else if (_isCashierTab) {
      titleText = 'Kasir';
    } else if (_isTopUpTab) {
      titleText = 'Top-Up Saldo';
    } else if (_isHistoryTab) {
      titleText = 'Riwayat Transaksi';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titleText,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
              ),
              if (_isOverviewTab)
                const Text('Monitoring seluruh area wisata', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mode Toggle Icon for Mobile
            if (MediaQuery.of(context).size.width < 900)
              IconButton(
                icon: Icon(
                  _isAdminMode ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                  color: _isAdminMode ? const Color(0xFFF43F5E) : const Color(0xFF64748B),
                  size: 24,
                ),
                onPressed: _isAdminMode ? _exitAdminMode : _showPINDialog,
                tooltip: _isAdminMode ? 'Keluar Admin' : 'Masuk Admin',
              ),
            if ((_isCashierTab && _cashierAmount > 0) || (_isTopUpTab && _topUpAmount > 0))
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFF64748B)),
                onPressed: _clearAmount,
                tooltip: 'Clear nominal',
              )
          ],
        )
      ],
    );
  }

  // Active dropdown for merchants in cashier mode (styled exactly like the mockup card)
  Widget _buildMerchantSelector() {
    if (!_isCashierTab && !_isTopUpTab) return const SizedBox.shrink();
    if (_merchantsList.isEmpty) return const SizedBox.shrink();
    
    final activeMerchant = _merchantsList.firstWhere((m) => m['id'] == _selectedMerchantId, orElse: () => _merchantsList[0]);
    final String activeName = activeMerchant['nama_warung'] ?? 'Warung';
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(color: Color(0x050F172A), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7), // Yellow pastel circular bg
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.storefront_rounded, color: Colors.amber, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activeName,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 2),
                Text(
                  'Merchant Resmi • ${activeMerchant['nama_pemilik'] ?? 'Kasir'}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedMerchantId,
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF64748B)),
              dropdownColor: Colors.white,
              onChanged: (int? newValue) {
                setState(() {
                  _selectedMerchantId = newValue;
                });
                _fetchDashboardData();
              },
              items: _merchantsList.map<DropdownMenuItem<int>>((Map<String, dynamic> merchant) {
                return DropdownMenuItem<int>(
                  value: merchant['id'] as int,
                  child: Text(
                    merchant['nama_pemilik'] ?? 'Kasir',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6)),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // Apple-style Display Card with large Indigo typography
  Widget _buildLEDAmountDisplay() {
    int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(color: Color(0x050F172A), blurRadius: 15, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _isCashierTab ? 'Nominal Debit Belanja' : 'Nominal Top-Up Saldo',
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
              ),
              const Text(
                'IDR',
                style: TextStyle(fontSize: 12, color: Color(0xFF3B82F6), fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _formatCurrency(activeAmount),
            style: const TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A), // Pure Slate Dark Text
            ),
          ),
        ],
      ),
    );
  }

  // Light blue buttons with rounded corners
  Widget _buildQuickAmountSelector() {
    final values = _isCashierTab ? [10000, 25000, 50000, 100000] : [20000, 50000, 100000, 200000];
    final isEnabled = _currentStatus == TransactionStatus.waitingForInput;

    return Row(
      children: values.map((val) {
        String text = '+${val ~/ 1000}k';
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: InkWell(
              onTap: isEnabled ? () => _addQuickAmount(val) : null,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isEnabled 
                      ? const Color(0xFFEFF6FF) 
                      : Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isEnabled ? const Color(0xFFBFDBFE) : Colors.transparent,
                  ),
                ),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: isEnabled ? const Color(0xFF2563EB) : Colors.grey[400],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDigitalKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '⌫'],
    ];

    return Column(
      children: [
        Expanded(
          child: Column(
            children: keys.map((row) {
              return Expanded(
                child: Row(
                  children: row.map((key) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: _buildKeypadButton(key),
                      ),
                    );
                  }).toList(),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        _buildKeypadActionButton(),
      ],
    );
  }

  // Large Blue Apple style Action button
  Widget _buildKeypadActionButton() {
    int activeAmount = _isCashierTab ? _cashierAmount : _topUpAmount;
    final bool canClick = activeAmount > 0 && _currentStatus == TransactionStatus.waitingForInput;
    
    return Container(
      height: 56,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: canClick ? const Color(0xFF3B82F6) : const Color(0xFFE2E8F0),
        boxShadow: canClick
            ? [BoxShadow(color: const Color(0xFF3B82F6).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))]
            : null,
      ),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        onPressed: canClick ? _startPaymentProcess : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isCashierTab ? Icons.check_box_rounded : Icons.account_balance_wallet_rounded, 
              color: canClick ? Colors.white : const Color(0xFF94A3B8),
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(
              _isCashierTab ? 'Proses Pembayaran' : 'Proses Top-Up Saldo',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: canClick ? Colors.white : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Right column active terminal console
  Widget _buildTerminalConsole() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _isCashierTab ? 'MESIN PEMOTONG SALDO' : 'MESIN PENGISI SALDO',
              style: TextStyle(
                fontSize: 11, 
                fontWeight: FontWeight.bold, 
                color: _isCashierTab ? const Color(0xFF8B5CF6) : const Color(0xFF10B981),
                letterSpacing: 1.0,
              ),
            ),
            if (kIsWeb)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Simulasi RFID', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 20,
                    width: 36,
                    child: Switch(
                      value: _showSimulator,
                      onChanged: (val) {
                        setState(() {
                          _showSimulator = val;
                        });
                      },
                      activeColor: const Color(0xFF3B82F6),
                    ),
                  )
                ],
              )
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
              boxShadow: const [
                BoxShadow(color: Color(0x050F172A), blurRadius: 20, offset: Offset(0, 8)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                children: [
                  _buildAnimatedNFCBackground(),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: _buildTerminalStateBody(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTerminalStateBody() {
    switch (_currentStatus) {
      case TransactionStatus.waitingForInput:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isCashierTab ? Icons.point_of_sale_rounded : Icons.add_card_rounded, 
              size: 70, 
              color: const Color(0xFFE2E8F0),
            ),
            const SizedBox(height: 20),
            Text(
              _isCashierTab ? 'Kasir Belanja Idle' : 'Top-Up Terminal Idle',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 8),
            Text(
              _isCashierTab 
                  ? 'Ketik nominal belanja lalu tekan "Proses Pembayaran".' 
                  : 'Ketik nominal top-up lalu tekan "Proses Top-Up".',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        );
        
      case TransactionStatus.waitingForCard:
      case TransactionStatus.processing:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            CircleAvatar(
              radius: 36,
              backgroundColor: (_isCashierTab ? const Color(0xFF3B82F6) : const Color(0xFF10B981)).withOpacity(0.1),
              child: Icon(
                _isCashierTab ? Icons.nfc_rounded : Icons.contactless_rounded, 
                size: 40, 
                color: _isCashierTab ? const Color(0xFF3B82F6) : const Color(0xFF10B981),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _currentStatus == TransactionStatus.processing 
                  ? 'Membaca data kartu...' 
                  : (_isCashierTab ? 'Siap Potong Saldo' : 'Siap Top-Up Saldo'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 6),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const Spacer(),
            if (_showSimulator) _buildInteractiveCardSimulator(),
          ],
        );

      case TransactionStatus.success:
        return _isCashierTab ? _buildHolographicReceipt() : _buildTopUpHolographicReceipt();

      case TransactionStatus.failed:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF1F2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFF43F5E)),
            ),
            const SizedBox(height: 20),
            const Text(
              'Transaksi Gagal',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFF43F5E)),
            ),
            const SizedBox(height: 6),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startPaymentProcess,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('Coba Lagi'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF1F5F9),
                foregroundColor: const Color(0xFF0F172A),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _resetTransaction,
              child: const Text('Batal & Reset', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
            ),
          ],
        );
    }
  }

  // White thermal receipt design for Top-up Success
  Widget _buildTopUpHolographicReceipt() {
    return _isPrinting
        ? _buildPrintingSpinner()
        : SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Thermal Receipt Voucher representation
                Container(
                  width: 280,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: const [BoxShadow(color: Color(0x0A0F172A), blurRadius: 12)],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      // Top header decoration
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF10B981), size: 18),
                          SizedBox(width: 6),
                          Text('E-WISATA CASHLESS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: 1.0)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text('Kuitansi Pengisian Saldo Resmi', style: TextStyle(fontSize: 9, color: Color(0xFF64748B))),
                      const SizedBox(height: 14),
                      
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text('- - - - - - - - - - - - - - - - - - - - - -', style: TextStyle(color: Color(0xFFCBD5E1))),
                      ),
                      
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
                        child: Column(
                          children: [
                            _buildReceiptRow('Wisatawan', touristName ?? 'N/A', isBold: true),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Status Kartu', 'AKTIF / TERDAFTAR', isGreen: true),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Nomor Chip UID', nfcUid ?? 'N/A'),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Loket Pengisian', 'Loket Utama Zone A'),
                            const Divider(height: 24, thickness: 1, color: Color(0xFFF1F5F9)),
                            _buildReceiptRow('Jumlah Top-Up', _formatCurrency(_topUpAmount), isGreen: true, isBold: true),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Saldo Akhir', loadedNewSaldo != null ? _formatCurrency(loadedNewSaldo!) : 'N/A', isBold: true),
                          ],
                        ),
                      ),
                      
                      const Text('- - - - - - - - - - - - - - - - - - - - - -', style: TextStyle(color: Color(0xFFCBD5E1))),
                      
                      // QR Code simulation
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Container(
                              height: 64,
                              width: 64,
                              decoration: BoxDecoration(
                                border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.qr_code_2_rounded, size: 48, color: Color(0xFF0F172A)),
                            ),
                            const SizedBox(height: 6),
                            const Text('SINKRONISASI CLOUD BERHASIL', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF10B981))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _generatePdfReceipt,
                      icon: const Icon(Icons.print_rounded, size: 14),
                      label: const Text('Cetak Struk', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF1F5F9),
                        foregroundColor: const Color(0xFF0F172A),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _resetTransaction,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      ),
                      child: const Text('Top-Up Baru', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    )
                  ],
                )
              ],
            ),
          );
  }

  // White thermal receipt design for Cashier checkout
  Widget _buildHolographicReceipt() {
    return _isPrinting
        ? _buildPrintingSpinner()
        : SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Thermal Receipt Voucher representation
                Container(
                  width: 280,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: const [BoxShadow(color: Color(0x0A0F172A), blurRadius: 12)],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      // Top header decoration
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_rounded, color: Color(0xFF3B82F6), size: 18),
                          SizedBox(width: 6),
                          Text('E-WISATA CASHLESS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: 1.0)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text('Nota Belanja Souvenir Resmi', style: TextStyle(fontSize: 9, color: Color(0xFF64748B))),
                      const SizedBox(height: 14),
                      
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text('- - - - - - - - - - - - - - - - - - - - - -', style: TextStyle(color: Color(0xFFCBD5E1))),
                      ),
                      
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
                        child: Column(
                          children: [
                            _buildReceiptRow('Wisatawan', touristName ?? 'Wisatawan', isBold: true),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Tipe Pembayaran', 'RFID Token Souvenir'),
                            const SizedBox(height: 6),
                            _buildReceiptRow('UID Kartu', nfcUid ?? 'N/A'),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Loket Kasir', _merchantsList.firstWhere((m) => m['id'] == _selectedMerchantId, orElse: () => {'nama_warung': 'Loket Kasir'})['nama_warung']),
                            const Divider(height: 24, thickness: 1, color: Color(0xFFF1F5F9)),
                            _buildReceiptRow('Nominal Belanja', _formatCurrency(_cashierAmount), isBold: true),
                            const SizedBox(height: 6),
                            _buildReceiptRow('Sisa Saldo', remainingSaldo != null ? _formatCurrency(remainingSaldo!) : 'N/A', isGreen: true, isBold: true),
                          ],
                        ),
                      ),
                      
                      const Text('- - - - - - - - - - - - - - - - - - - - - -', style: TextStyle(color: Color(0xFFCBD5E1))),
                      
                      // QR Code simulation
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Container(
                              height: 64,
                              width: 64,
                              decoration: BoxDecoration(
                                border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.qr_code_2_rounded, size: 48, color: Color(0xFF0F172A)),
                            ),
                            const SizedBox(height: 6),
                            const Text('TIKET WAHANA VALID', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF3B82F6))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _generatePdfReceipt,
                      icon: const Icon(Icons.print_rounded, size: 14),
                      label: const Text('Cetak Struk', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF1F5F9),
                        foregroundColor: const Color(0xFF0F172A),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _resetTransaction,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3B82F6),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      ),
                      child: const Text('Transaksi Baru', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    )
                  ],
                )
              ],
            ),
          );
  }

  Widget _buildPrintingSpinner() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: Color(0xFF3B82F6)),
        const SizedBox(height: 16),
        const Text(
          'Mencetak Struk Kasir...',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
        ),
        const SizedBox(height: 6),
        const Text(
          'Mengirim data ke Bluetooth Printer...',
          style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
      ],
    );
  }

  Widget _buildReceiptRow(String label, String value, {bool isBold = false, bool isGreen = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
            color: isGreen 
                ? const Color(0xFF10B981) 
                : (isBold ? const Color(0xFF0F172A) : const Color(0xFF334155)),
          ),
        ),
      ],
    );
  }

  // Card Simulator styled with rounded gradients
  Widget _buildInteractiveCardSimulator() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: Colors.amber, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text(
                'SIMULATOR CHIP RFID',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          Container(
            height: 80,
            width: 150,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _isCashierTab
                    ? [const Color(0xFFEC4899), const Color(0xFF8B5CF6)]
                    : [const Color(0xFF34D399), const Color(0xFF059669)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: (_isCashierTab ? const Color(0xFFEC4899) : const Color(0xFF34D399)).withOpacity(0.15),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 16,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.amber[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: 14),
                    ],
                  ),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'E-WISATA CARD',
                        style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.0),
                      ),
                      Text(
                        'Balanced Cashless',
                        style: TextStyle(fontSize: 6, color: Colors.white70),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _simulateCardTap,
            icon: const Icon(Icons.touch_app_rounded, size: 14),
            label: const Text('Simulasikan Tap Kartu', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              elevation: 0,
            ),
          )
        ],
      ),
    );
  }

  // Left Column Dashboard reporting view (Merchant history tab)
  Widget _buildDashboardView() {
    return _isLoadingDashboard 
        ? const Center(child: CircularProgressIndicator())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'REKAP KEUANGAN WARUNG',
                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold, letterSpacing: 1.2),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Color(0xFF3B82F6)),
                    onPressed: _fetchDashboardData,
                    tooltip: 'Refresh Laporan',
                  )
                ],
              ),
              const SizedBox(height: 10),
              
              // Stats Card 1: Total Earnings
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEFF6FF), Color(0xFFDBEAFE)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('PENDAPATAN WARUNG HARI INI', style: TextStyle(fontSize: 10, color: Color(0xFF2563EB), fontWeight: FontWeight.bold, letterSpacing: 1.0)),
                    const SizedBox(height: 6),
                    Text(
                      _formatCurrency(_totalEarnings),
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF1E40AF)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              
              // Stats Card 2: Transactions Count
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TRANSAKSI BERHASIL', style: TextStyle(fontSize: 9, color: Color(0xFF64748B), letterSpacing: 1.0)),
                        SizedBox(height: 4),
                        Text('Jumlah struk terbit', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                      ],
                    ),
                    Text(
                      '$_totalTransactionsCount Kali',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                    ),
                  ],
                ),
              ),
              
              // Show recent transactions inside left column if on Mobile
              if (MediaQuery.of(context).size.width < 900) ...[
                const SizedBox(height: 24),
                const Text(
                  '10 TRANSAKSI TERAKHIR',
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
                const SizedBox(height: 8),
                Expanded(child: _buildTransactionsListViewWidget()),
              ],
            ],
          );
  }



  // Reusable transactions list widget (Apple Outlined Style)
  Widget _buildTransactionsListViewWidget() {
    if (_recentTransactions.isEmpty) {
      return const Center(
        child: Text(
          'Belum ada transaksi hari ini.',
          style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      itemCount: _recentTransactions.length,
      itemBuilder: (context, index) {
        final tx = _recentTransactions[index];
        final String name = tx['users'] != null ? tx['users']['nama'] : 'Wisatawan';
        final int nominal = tx['nominal'] ?? 0;
        final String time = _formatTime(tx['created_at']);

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFFECFDF5),
                    child: const Icon(Icons.arrow_downward_rounded, size: 18, color: Color(0xFF10B981)),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                      const SizedBox(height: 2),
                      Text('Transaksi Berhasil • $time WIB', style: const TextStyle(fontSize: 9, color: Color(0xFF64748B))),
                    ],
                  ),
                ],
              ),
              Text(
                '+ ${_formatCurrency(nominal)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF10B981)),
              ),
            ],
          ),
        );
      },
    );
  }

  // Central Manager Dashboard UI View (Matches mockup 1 exactly)
  Widget _buildAdminOverviewView() {
    return _isLoadingAdminDashboard
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _fetchAdminDashboardData,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Ringkasan Keuangan',
                        style: TextStyle(fontSize: 15, color: Color(0xFF0F172A), fontWeight: FontWeight.w900),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh_rounded, color: Color(0xFF3B82F6)),
                        onPressed: () {
                          _fetchMerchants();
                          _fetchAdminDashboardData();
                        },
                        tooltip: 'Refresh Dashboard',
                      )
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Financial Summary Cards (Layout matches mockup 1)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final bool isWide = constraints.maxWidth > 700;
                      return isWide 
                          ? Row(
                              children: [
                                Expanded(child: _buildOverviewCard('Total Uang Masuk (Top-Up)', _totalTopUpsSum, const Color(0xFF3B82F6), Icons.trending_up_rounded)),
                                const SizedBox(width: 12),
                                Expanded(child: _buildOverviewCard('Total Belanja (Realisasi)', _totalSpendingsSum, const Color(0xFF10B981), Icons.shopping_bag_outlined)),
                              ],
                            )
                          : Column(
                              children: [
                                _buildOverviewCard('Total Uang Masuk (Top-Up)', _totalTopUpsSum, const Color(0xFF3B82F6), Icons.trending_up_rounded),
                                const SizedBox(height: 10),
                                _buildOverviewCard('Total Belanja (Realisasi)', _totalSpendingsSum, const Color(0xFF10B981), Icons.shopping_bag_outlined),
                              ],
                            );
                    },
                  ),
                  const SizedBox(height: 12),
                  
                  // Card 3: Saldo Beredar (Horizontal Layout card at the bottom of Grid)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: const [BoxShadow(color: Color(0x030F172A), blurRadius: 10)],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Saldo Beredar (Outstanding)', style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text(
                              _formatCurrency(_totalTopUpsSum - _totalSpendingsSum),
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.orange),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFFFF7ED), shape: BoxShape.circle),
                          child: const Icon(Icons.sync_alt_rounded, color: Colors.orange, size: 24),
                        )
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Two columns ranking vs live logs
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final bool isWide = constraints.maxWidth > 800;
                      return isWide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: _buildDashboardSection('Peringkat Merchant', _buildBestSellingMerchantsList()),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  flex: 6,
                                  child: _buildDashboardSection('Log Transaksi Global', _buildGlobalLiveTransactionsTable()),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                _buildDashboardSection('Peringkat Merchant', _buildBestSellingMerchantsList()),
                                const SizedBox(height: 20),
                                _buildDashboardSection('Log Transaksi Global', _buildGlobalLiveTransactionsTable()),
                              ],
                            );
                    },
                  ),
                ],
              ),
            ),
          );
  }

  Widget _buildOverviewCard(String title, int amount, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(color: Color(0x030F172A), blurRadius: 10),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _formatCurrency(amount),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          )
        ],
      ),
    );
  }

  Widget _buildDashboardSection(String title, Widget content) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [BoxShadow(color: Color(0x030F172A), blurRadius: 15)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
              ),
              const SizedBox.shrink(),
            ],
          ),
          const SizedBox(height: 16),
          content,
        ],
      ),
    );
  }

  Widget _buildBestSellingMerchantsList() {
    if (_bestSellingMerchants.isEmpty) {
      return const Center(child: Text('Belum ada data penjualan.', style: TextStyle(color: Colors.grey)));
    }
    
    int maxRevenue = 1;
    for (var m in _bestSellingMerchants) {
      int rev = m['total_omzet'] as int;
      if (rev > maxRevenue) maxRevenue = rev;
    }
    
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _bestSellingMerchants.length,
      itemBuilder: (context, index) {
        final m = _bestSellingMerchants[index];
        final String name = m['nama_warung'] ?? 'Warung';
        final int omzet = m['total_omzet'] ?? 0;
        final double proportion = omzet / maxRevenue;
        
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '#${index + 1} $name',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatCurrency(omzet),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF3B82F6)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Stack(
                children: [
                  Container(
                    height: 6,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  FractionallySizedBox(
                     widthFactor: proportion.clamp(0.001, 1.0),
                     child: Container(
                       height: 6,
                       decoration: BoxDecoration(
                         gradient: const LinearGradient(
                           colors: [Color(0xFF3B82F6), Color(0xFFEC4899)],
                         ),
                         borderRadius: BorderRadius.circular(3),
                       ),
                     ),
                   ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlobalLiveTransactionsTable() {
    if (_allTransactionsGlobal.isEmpty) {
      return const Center(child: Text('Belum ada transaksi di tempat wisata.', style: TextStyle(color: Colors.grey)));
    }
    
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _allTransactionsGlobal.length > 5 ? 5 : _allTransactionsGlobal.length,
      itemBuilder: (context, index) {
        final tx = _allTransactionsGlobal[index];
        final String userName = tx['users'] != null ? tx['users']['nama'] : 'Wisatawan';
        final String merchantName = tx['merchants'] != null ? tx['merchants']['nama_warung'] : 'Warung Umum';
        final int nominal = tx['nominal'] ?? 0;
        final String time = _formatTime(tx['created_at']);
        
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0xFFECFDF5),
                    child: const Icon(Icons.arrow_downward_rounded, size: 16, color: Color(0xFF10B981)),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(userName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                      const SizedBox(height: 2),
                      Text('Membeli di: $merchantName', style: const TextStyle(fontSize: 8, color: Color(0xFF64748B))),
                      Text(time, style: const TextStyle(fontSize: 8, color: Color(0xFF94A3B8))),
                    ],
                  ),
                ],
              ),
              Text(
                _formatCurrency(nominal),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
              ),
            ],
          ),
        );
      },
    );
  }

  // Global Transaction Reports Page (Matches mockup 4 exactly!)
  Widget _buildGlobalHistoryView() {
    final double averageVal = _allTransactionsGlobal.isNotEmpty ? _totalSpendingsSum / _allTransactionsGlobal.length : 0.0;
    
    return _isExporting
        ? _buildExportSpinner()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Filters row (mockup 4 header)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Laporan Global', style: TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Color(0xFF3B82F6), size: 18),
                    onPressed: () {
                      _fetchMerchants();
                      _fetchAdminDashboardData();
                    },
                    tooltip: 'Refresh data',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              // Time selector pills
              Row(
                children: ['Hari Ini', 'Minggu Ini', 'Bulan Ini', 'Kustom'].map((text) {
                  final bool isActive = _activeTimeFilter == text;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _activeTimeFilter = text;
                          });
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isActive ? const Color(0xFF3B82F6) : Colors.white,
                            border: Border.all(color: isActive ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                text,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isActive ? Colors.white : const Color(0xFF64748B),
                                ),
                              ),
                              if (text == 'Kustom') ...[
                                const SizedBox(width: 4),
                                Icon(Icons.calendar_today_rounded, size: 10, color: isActive ? Colors.white : const Color(0xFF64748B)),
                              ]
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              
              // Statistics Row
              Row(
                children: [
                  Expanded(child: _buildMiniStatCard('Total Transaksi', '${_allTransactionsGlobal.length}')),
                  const SizedBox(width: 8),
                  Expanded(child: _buildMiniStatCard('Total Nilai', _formatCurrency(_totalSpendingsSum))),
                  const SizedBox(width: 8),
                  Expanded(child: _buildMiniStatCard('Rata-rata', _formatCurrency(averageVal.toInt()))),
                ],
              ),
              const SizedBox(height: 16),
              
              // Global transaction table list
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: ListView.builder(
                    itemCount: _allTransactionsGlobal.length,
                    itemBuilder: (context, index) {
                      final tx = _allTransactionsGlobal[index];
                      final String userName = tx['users'] != null ? tx['users']['nama'] : 'Wisatawan';
                      final String merchantName = tx['merchants'] != null ? tx['merchants']['nama_warung'] : 'Warung Umum';
                      final int nominal = tx['nominal'] ?? 0;
                      final String time = _formatTime(tx['created_at']);
                      
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: const Color(0xFFECFDF5),
                                  child: const Icon(Icons.arrow_downward_rounded, size: 16, color: Color(0xFF10B981)),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(userName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                                    const SizedBox(height: 2),
                                    Text('$merchantName • $time WIB', style: const TextStyle(fontSize: 8, color: Color(0xFF64748B))),
                                  ],
                                ),
                              ],
                            ),
                            Text(
                              '+ ${_formatCurrency(nominal)}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF10B981)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              
              // Export button
              ElevatedButton.icon(
                onPressed: _generatePdfReport,
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Export Laporan', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF3B82F6),
                  elevation: 0,
                  side: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              )
            ],
          );
  }

  Widget _buildMiniStatCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildExportSpinner() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircularProgressIndicator(color: Color(0xFF3B82F6)),
        const SizedBox(height: 16),
        const Text(
          'Mengekspor Laporan...',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
        ),
        const SizedBox(height: 6),
        const Text(
          'Mengompilasi data transaksi ke Excel/PDF...',
          style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
      ],
    );
  }

  // Mobile navigation & overlays
  Widget _buildMobileNavBar() {
    return NavigationBar(
      selectedIndex: _currentTab,
      onDestinationSelected: (index) {
        setState(() {
          _currentTab = index;
          _resetTransaction();
        });
        if (_isAdminMode && index == 0) {
          _fetchAdminDashboardData();
        }
      },
      backgroundColor: Colors.white,
      indicatorColor: const Color(0xFF3B82F6).withOpacity(0.12),
      destinations: _isAdminMode
          ? const [
              NavigationDestination(icon: Icon(Icons.analytics_rounded), label: 'Overview'),
              NavigationDestination(icon: Icon(Icons.point_of_sale_rounded), label: 'Kasir'),
              NavigationDestination(icon: Icon(Icons.add_card_rounded), label: 'Top-Up'),
              NavigationDestination(icon: Icon(Icons.list_alt_rounded), label: 'Riwayat'),
            ]
          : const [
              NavigationDestination(icon: Icon(Icons.point_of_sale_rounded), label: 'Kasir'),
              NavigationDestination(icon: Icon(Icons.add_card_rounded), label: 'Top-Up'),
              NavigationDestination(icon: Icon(Icons.analytics_rounded), label: 'Riwayat'),
            ],
    );
  }

  Widget _buildMobileTerminalOverlay() {
    return Container(
      height: 350,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 1.5)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Stack(
          children: [
            _buildAnimatedNFCBackground(),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: _buildTerminalStateBody(),
            ),
          ],
        ),
      ),
    );
  }

  // NFC UID readers
  List<int>? _getNfcId(NfcTag tag) {
    final Map<String, dynamic> data = tag.data;
    final List<dynamic>? identifier = data['nfca']?['identifier'] ??
        data['nfcb']?['identifier'] ??
        data['nfcf']?['identifier'] ??
        data['nfcv']?['identifier'] ??
        data['isodep']?['identifier'] ??
        data['mifareclassic']?['identifier'] ??
        data['mifareultralight']?['identifier'];
    return identifier?.cast<int>();
  }

  String _toHexString(List<int> bytes) {
    return bytes.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
  }

  Widget _buildKeypadButton(String key) {
    final isEnabled = _currentStatus == TransactionStatus.waitingForInput;
    final isSpecial = key == 'C' || key == '⌫';
    
    Color textColor = const Color(0xFF0F172A);
    if (isSpecial) {
      textColor = key == 'C' ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    }
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEnabled ? () => _handleKeypadTap(key) : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: isEnabled ? Colors.white : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isEnabled ? const Color(0xFFE2E8F0) : Colors.transparent,
            ),
          ),
          alignment: Alignment.center,
          child: key == '⌫'
              ? Icon(Icons.backspace_outlined, color: isEnabled ? const Color(0xFF64748B) : Colors.grey[300], size: 20)
              : Text(
                  key,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isEnabled ? textColor : Colors.grey[300],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildAnimatedNFCBackground() {
    if (_currentStatus != TransactionStatus.waitingForCard && 
        _currentStatus != TransactionStatus.processing) {
      return const SizedBox.shrink();
    }
    
    final color = _isCashierTab ? const Color(0xFF3B82F6) : const Color(0xFF10B981);
    
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: List.generate(3, (index) {
            double pulse = _pulseController.value + (index * 0.33);
            if (pulse > 1.0) pulse -= 1.0;
            
            double radius = 100 + (pulse * 250);
            double opacity = (1.0 - pulse) * 0.15;
            
            return Container(
              width: radius,
              height: radius,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: color.withOpacity(opacity),
                  width: 2.0,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
